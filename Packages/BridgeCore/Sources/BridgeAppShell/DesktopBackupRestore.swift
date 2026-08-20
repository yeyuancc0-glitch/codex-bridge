import BridgePersistence
import BridgePipeline
import BridgeRepositories
import CryptoKit
import Darwin
import Foundation
import GRDB

/// Fail-closed backup snapshot and restore support for the desktop data root.
///
/// Snapshotting uses the SQLite online backup API (through GRDB) from a
/// separate read-only connection, so every snapshot is a consistent
/// point-in-time copy even while the live stores are open. Restore stages a
/// validated package into a private root, records a pending marker, and only
/// applies the atomic swap at the next launch, before any database is opened.
enum DesktopBackupRestoreError: Error, Equatable, Sendable {
  case invalidDataDirectory
  case invalidPackageURL
  case invalidPackage
  case invalidSnapshot
  case unsupportedSnapshotSchema(String)
  case backupUnavailable
  case markerUnavailable
  case dataRootDrift
  case stagingUnavailable
  case restoreIncomplete
  case restoreAlreadyPending
}

struct DesktopBackupDatabaseSnapshot: Equatable, Sendable {
  let name: String
  let byteCount: Int64
  let sha256: String
  let schemaVersion: String
}

struct DesktopBackupSnapshotSummary: Equatable, Sendable {
  let databases: [DesktopBackupDatabaseSnapshot]
  let createdAt: Date
}

enum DesktopBackupSnapshotProvider {
  static let allowedNames = DesktopBackupPackage.allowedEntryNames.sorted()

  /// Creates a private `0700` directory inside the data root containing
  /// online-backup snapshots of the three durable SQLite files. Returns the
  /// directory and a typed summary that carries no raw events, project roots,
  /// Thread IDs or paths.
  static func makeSnapshotDirectory(
    dataDirectoryURL: URL,
    now: Date = Date()
  ) throws -> (directoryURL: URL, summary: DesktopBackupSnapshotSummary) {
    let dataRoot = try DesktopRestoreCoordinator.openDirectory(
      dataDirectoryURL, requirePrivate: true)
    defer { Darwin.close(dataRoot) }

    let name = ".codex-bridge-snapshot-\(UUID().uuidString.lowercased())"
    guard mkdirat(dataRoot, name, S_IRWXU) == 0 else {
      throw DesktopBackupRestoreError.backupUnavailable
    }
    let directoryURL = dataDirectoryURL.appendingPathComponent(name, isDirectory: true)
    var completed = false
    defer {
      if !completed {
        DesktopRestoreCoordinator.removePrivateDirectory(name, parent: dataRoot)
      }
    }
    let directory = try DesktopRestoreCoordinator.openDirectory(directoryURL, requirePrivate: true)
    defer { Darwin.close(directory) }

    var databases: [DesktopBackupDatabaseSnapshot] = []
    for fileName in allowedNames {
      let snapshotName = ".codex-bridge-snapshot-\(UUID().uuidString.lowercased()).sqlite"
      let snapshotURL = directoryURL.appendingPathComponent(snapshotName, isDirectory: false)
      try backup(
        source: dataDirectoryURL.appendingPathComponent(fileName).path,
        destination: snapshotURL.path
      )
      guard try DesktopRestoreCoordinator.makePrivateRegularFile(snapshotURL) else {
        throw DesktopBackupRestoreError.invalidSnapshot
      }
      let bytes = try DesktopRestoreCoordinator.readEntry(
        snapshotName, from: directory, maximumBytes: DesktopBackupPackage.maximumEntryBytes)
      let version = try schemaVersion(of: fileName, snapshotPath: snapshotURL.path)
      databases.append(
        DesktopBackupDatabaseSnapshot(
          name: fileName,
          byteCount: Int64(bytes.count),
          sha256: DesktopRestoreCoordinator.digest(bytes),
          schemaVersion: version
        )
      )
      guard renameat(directory, snapshotName, directory, fileName) == 0 else {
        throw DesktopBackupRestoreError.backupUnavailable
      }
    }
    guard fsync(directory) == 0 else { throw DesktopBackupRestoreError.backupUnavailable }
    completed = true
    return (
      directoryURL: directoryURL,
      summary: DesktopBackupSnapshotSummary(databases: databases, createdAt: now)
    )
  }

  /// Uses SQLite online backup from a separate read-only connection.
  private static func backup(source sourcePath: String, destination destinationPath: String) throws
  {
    var metadata = stat()
    guard lstat(sourcePath, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw DesktopBackupRestoreError.backupUnavailable
    }
    let source: DatabaseQueue
    let destination: DatabaseQueue
    do {
      source = try DatabaseQueue(path: sourcePath, configuration: readOnlyConfiguration())
      destination = try DatabaseQueue(path: destinationPath)
    } catch {
      throw DesktopBackupRestoreError.backupUnavailable
    }
    do {
      try source.backup(to: destination)
      let journalMode = try destination.writeWithoutTransaction { db in
        try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
      }
      guard journalMode?.lowercased() == "delete" else {
        throw DesktopBackupRestoreError.invalidSnapshot
      }
      let quick = try destination.read { db in
        try String.fetchAll(db, sql: "PRAGMA quick_check(1)")
      }
      guard quick == ["ok"] else { throw DesktopBackupRestoreError.invalidSnapshot }
      try destination.close()
      try source.close()
    } catch {
      try? destination.close()
      try? source.close()
      throw error
    }
  }

  private static func schemaVersion(of name: String, snapshotPath: String) throws -> String {
    let queue: DatabaseQueue
    do {
      queue = try DatabaseQueue(path: snapshotPath, configuration: readOnlyConfiguration())
    } catch {
      throw DesktopBackupRestoreError.invalidSnapshot
    }
    defer { try? queue.close() }
    return try queue.read { db in
      switch name {
      case "task-events.sqlite":
        guard try db.tableExists("grdb_migrations") else {
          throw DesktopBackupRestoreError.invalidSnapshot
        }
        let identifiers = try String.fetchAll(
          db,
          sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        )
        return "event:\(identifiers.joined(separator: ","))"
      case "application.sqlite":
        guard try db.tableExists("bridge_repository_meta") else {
          throw DesktopBackupRestoreError.invalidSnapshot
        }
        let versions = try Int64.fetchAll(
          db,
          sql: "SELECT schema_version FROM bridge_repository_meta WHERE singleton = 1"
        )
        guard versions.count == 1 else { throw DesktopBackupRestoreError.invalidSnapshot }
        return "repository:\(versions[0])"
      case "supervision-ledger.sqlite":
        guard try db.tableExists("bridge_supervision_meta") else {
          throw DesktopBackupRestoreError.invalidSnapshot
        }
        let versions = try Int64.fetchAll(
          db,
          sql: "SELECT schema_version FROM bridge_supervision_meta WHERE singleton = 1"
        )
        guard versions.count == 1 else { throw DesktopBackupRestoreError.invalidSnapshot }
        return "supervision:\(versions[0])"
      default:
        throw DesktopBackupRestoreError.invalidSnapshot
      }
    }
  }

  private static func readOnlyConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(5)
    return configuration
  }
}

struct DesktopRestoreMarker: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let operationID: String
  let createdAt: Date
  let targetDevice: UInt64
  let targetInode: UInt64
  let packageDigest: String
  let stagedDirectoryName: String
  let retainedDirectoryName: String
}

struct DesktopRestoreResult: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case succeeded
    case failed
  }

  static let schemaVersion = 1

  let schemaVersion: Int
  let operationID: String
  let createdAt: Date
  let status: Status
  let message: String
  let databaseSchemaVersions: [String: String]
}

enum DesktopRestoreOutcome: Equatable, Sendable {
  case none
  case succeeded(DesktopRestoreResult)
  case failed(DesktopRestoreResult)
}

/// Restore coordinator. The live databases are never touched until the next
/// launch, when `performPendingRestoreIfNeeded` runs before any store opens.
enum DesktopRestoreCoordinator {
  static let markerFileName = "restore-pending.json"
  static let resultFileName = "restore-result.json"
  private static let stagingRootName = "restore-staging"
  private static let retainedRootName = "restore-retained"
  private static let validationRootName = ".codex-bridge-restore-validate"
  private static let maximumMarkerBytes = 64 * 1_024

  static func stagingRoot(dataDirectoryURL: URL) -> URL {
    dataDirectoryURL.appendingPathComponent(stagingRootName, isDirectory: true)
  }

  static func retainedRoot(dataDirectoryURL: URL) -> URL {
    dataDirectoryURL.appendingPathComponent(retainedRootName, isDirectory: true)
  }

  static func markerURL(dataDirectoryURL: URL) -> URL {
    dataDirectoryURL.appendingPathComponent(markerFileName, isDirectory: false)
  }

  static func resultURL(dataDirectoryURL: URL) -> URL {
    dataDirectoryURL.appendingPathComponent(resultFileName, isDirectory: false)
  }

  static func pendingMarkerExists(dataDirectoryURL: URL) -> Bool {
    var metadata = stat()
    return lstat(markerURL(dataDirectoryURL: dataDirectoryURL).path, &metadata) == 0
  }

  static func latestResult(dataDirectoryURL: URL) -> DesktopRestoreResult? {
    let url = resultURL(dataDirectoryURL: dataDirectoryURL)
    let dataRoot: Int32
    do {
      dataRoot = try openDirectory(url.deletingLastPathComponent(), requirePrivate: true)
    } catch {
      return nil
    }
    defer { Darwin.close(dataRoot) }
    guard
      let bytes = try? readEntry(
        url.lastPathComponent, from: dataRoot, maximumBytes: Int64(maximumMarkerBytes))
    else {
      return nil
    }
    return try? decodeResult(bytes)
  }

  /// Stages a user-selected package into a private root, validates it, and
  /// records a pending marker. Returns the marker; the swap happens later.
  @discardableResult
  static func prepareRestore(
    packageURL: URL,
    dataDirectoryURL: URL,
    now: Date = Date()
  ) throws -> DesktopRestoreMarker {
    guard !pendingMarkerExists(dataDirectoryURL: dataDirectoryURL) else {
      throw DesktopBackupRestoreError.restoreAlreadyPending
    }
    _ = try DesktopBackupPackage.validate(at: packageURL)
    let dataRoot = try openDirectory(dataDirectoryURL, requirePrivate: true)
    defer { Darwin.close(dataRoot) }
    var rootMetadata = stat()
    guard fstat(dataRoot, &rootMetadata) == 0 else {
      throw DesktopBackupRestoreError.invalidDataDirectory
    }

    let operationID = UUID().uuidString.lowercased()
    let stagedDirectoryName = "restore-\(operationID)"
    let retainedDirectoryName = "retained-\(operationID)"
    let stagingRootURL = stagingRoot(dataDirectoryURL: dataDirectoryURL)
    try createPrivateDirectory(stagingRootURL)
    let stagingRootFD = try openDirectory(stagingRootURL, requirePrivate: true)
    defer { Darwin.close(stagingRootFD) }
    let stagedDirectoryURL = stagingRootURL.appendingPathComponent(
      stagedDirectoryName, isDirectory: true)
    try createPrivateDirectory(stagedDirectoryURL)
    let staged = try openDirectory(stagedDirectoryURL, requirePrivate: true)
    defer { Darwin.close(staged) }
    var stagedComplete = false
    defer {
      if !stagedComplete {
        removePrivateDirectory(stagedDirectoryName, parent: stagingRootFD)
      }
    }

    try copyPackageEntries(from: packageURL, to: staged)
    _ = try DesktopBackupPackage.validate(at: stagedDirectoryURL)
    try validateSnapshotSchemas(in: stagedDirectoryURL, dataDirectoryURL: dataDirectoryURL)
    let packageDigest = try packageDigest(of: stagedDirectoryURL)

    let marker = DesktopRestoreMarker(
      schemaVersion: DesktopRestoreMarker.schemaVersion,
      operationID: operationID,
      createdAt: now,
      targetDevice: UInt64(rootMetadata.st_dev),
      targetInode: UInt64(rootMetadata.st_ino),
      packageDigest: packageDigest,
      stagedDirectoryName: stagedDirectoryName,
      retainedDirectoryName: retainedDirectoryName
    )
    try writeMarker(marker, to: dataRoot)
    stagedComplete = true
    return marker
  }

  /// Applies a pending restore at launch, before any store opens. On
  /// recoverable failure the original data is preserved and the app can
  /// continue; on catastrophic failure this throws `restoreIncomplete`.
  @discardableResult
  static func performPendingRestoreIfNeeded(
    dataDirectoryURL: URL,
    now: Date = Date()
  ) throws -> DesktopRestoreOutcome {
    let markerURL = markerURL(dataDirectoryURL: dataDirectoryURL)
    var markerMetadata = stat()
    guard lstat(markerURL.path, &markerMetadata) == 0 else {
      if errno == ENOENT { return .none }
      throw DesktopBackupRestoreError.markerUnavailable
    }
    let marker = try readMarker(markerURL)
    guard marker.schemaVersion == DesktopRestoreMarker.schemaVersion else {
      throw DesktopBackupRestoreError.markerUnavailable
    }

    let dataRoot = try openDirectory(dataDirectoryURL, requirePrivate: true)
    defer { Darwin.close(dataRoot) }
    var rootMetadata = stat()
    guard fstat(dataRoot, &rootMetadata) == 0,
      UInt64(rootMetadata.st_dev) == marker.targetDevice,
      UInt64(rootMetadata.st_ino) == marker.targetInode
    else {
      _ = try? writeResult(
        DesktopRestoreResult(
          schemaVersion: DesktopRestoreResult.schemaVersion,
          operationID: marker.operationID,
          createdAt: now,
          status: .failed,
          message: "数据目录身份已变化，已取消恢复；原有数据未改动。",
          databaseSchemaVersions: [:]
        ),
        to: dataRoot
      )
      throw DesktopBackupRestoreError.dataRootDrift
    }

    let stagedDirectoryURL = stagingRoot(dataDirectoryURL: dataDirectoryURL)
      .appendingPathComponent(marker.stagedDirectoryName, isDirectory: true)
    let retainedDirectoryURL = retainedRoot(dataDirectoryURL: dataDirectoryURL)
      .appendingPathComponent(marker.retainedDirectoryName, isDirectory: true)

    let stagedIntact: Bool
    if (try? openDirectory(stagedDirectoryURL, requirePrivate: true)) != nil {
      stagedIntact = (try? packageDigest(of: stagedDirectoryURL)) == marker.packageDigest
    } else {
      stagedIntact = false
    }

    guard stagedIntact else {
      return try recoverInterruptedRestore(
        marker: marker,
        dataDirectoryURL: dataDirectoryURL,
        dataRoot: dataRoot,
        retainedDirectoryURL: retainedDirectoryURL,
        now: now
      )
    }

    let retainedRootURL = retainedRoot(dataDirectoryURL: dataDirectoryURL)
    try createPrivateDirectory(retainedRootURL)
    try createPrivateDirectory(retainedDirectoryURL)
    let retained = try openDirectory(retainedDirectoryURL, requirePrivate: true)
    defer { Darwin.close(retained) }
    let staged = try openDirectory(stagedDirectoryURL, requirePrivate: true)
    defer { Darwin.close(staged) }

    var movedToRetained: [String] = []
    var movedToLive: [String] = []
    do {
      for name in DesktopBackupSnapshotProvider.allowedNames {
        try moveWithCompanions(name: name, from: dataRoot, to: retained)
        movedToRetained.append(name)
      }
      for name in DesktopBackupSnapshotProvider.allowedNames {
        guard renameat(staged, name, dataRoot, name) == 0 else {
          throw DesktopBackupRestoreError.stagingUnavailable
        }
        movedToLive.append(name)
      }
      guard fsync(dataRoot) == 0, fsync(staged) == 0, fsync(retained) == 0 else {
        throw DesktopBackupRestoreError.backupUnavailable
      }
    } catch {
      rollbackSwap(
        dataRoot: dataRoot,
        retained: retained,
        staged: staged,
        movedToLive: movedToLive,
        movedToRetained: movedToRetained
      )
      _ = try? writeResult(
        DesktopRestoreResult(
          schemaVersion: DesktopRestoreResult.schemaVersion,
          operationID: marker.operationID,
          createdAt: now,
          status: .failed,
          message: "数据库交换未完成，已保留原有数据。",
          databaseSchemaVersions: [:]
        ),
        to: dataRoot
      )
      throw DesktopBackupRestoreError.restoreIncomplete
    }

    do {
      try validateLiveStores(dataDirectoryURL: dataDirectoryURL)
    } catch {
      rollbackSwap(
        dataRoot: dataRoot,
        retained: retained,
        staged: staged,
        movedToLive: movedToLive,
        movedToRetained: movedToRetained
      )
      _ = try? writeResult(
        DesktopRestoreResult(
          schemaVersion: DesktopRestoreResult.schemaVersion,
          operationID: marker.operationID,
          createdAt: now,
          status: .failed,
          message: "恢复后的数据库未通过完整性校验，已回滚并使用原有数据。",
          databaseSchemaVersions: [:]
        ),
        to: dataRoot
      )
      throw DesktopBackupRestoreError.restoreIncomplete
    }

    let schemaVersions = try? liveSchemaVersions(dataDirectoryURL: dataDirectoryURL)
    let result = DesktopRestoreResult(
      schemaVersion: DesktopRestoreResult.schemaVersion,
      operationID: marker.operationID,
      createdAt: now,
      status: .succeeded,
      message: "备份恢复完成。",
      databaseSchemaVersions: schemaVersions ?? [:]
    )
    try writeResult(result, to: dataRoot)
    _ = unlinkat(dataRoot, markerFileName, 0)
    guard fsync(dataRoot) == 0 else { throw DesktopBackupRestoreError.markerUnavailable }
    if let stagingRootFD = try? openDirectory(
      stagingRoot(dataDirectoryURL: dataDirectoryURL), requirePrivate: true)
    {
      removePrivateDirectory(marker.stagedDirectoryName, parent: stagingRootFD)
      Darwin.close(stagingRootFD)
    }
    if let retainedRootFD = try? openDirectory(
      retainedRoot(dataDirectoryURL: dataDirectoryURL), requirePrivate: true)
    {
      removeRetainedDirectory(marker.retainedDirectoryName, parent: retainedRootFD)
      Darwin.close(retainedRootFD)
    }
    return .succeeded(result)
  }

  private static func recoverInterruptedRestore(
    marker: DesktopRestoreMarker,
    dataDirectoryURL: URL,
    dataRoot: Int32,
    retainedDirectoryURL: URL,
    now: Date
  ) throws -> DesktopRestoreOutcome {
    let retainedExists = (try? openDirectory(retainedDirectoryURL, requirePrivate: true)) != nil
    if retainedExists {
      let retained = try openDirectory(retainedDirectoryURL, requirePrivate: true)
      defer { Darwin.close(retained) }
      for name in DesktopBackupSnapshotProvider.allowedNames {
        for candidate in [name, name + "-wal", name + "-shm"] {
          var metadata = stat()
          if fstatat(retained, candidate, &metadata, 0) == 0 {
            _ = renameat(retained, candidate, dataRoot, candidate)
          }
        }
      }
      guard fsync(dataRoot) == 0 else {
        throw DesktopBackupRestoreError.restoreIncomplete
      }
    }
    if (try? validateLiveStores(dataDirectoryURL: dataDirectoryURL)) != nil {
      let result = DesktopRestoreResult(
        schemaVersion: DesktopRestoreResult.schemaVersion,
        operationID: marker.operationID,
        createdAt: now,
        status: .failed,
        message: retainedExists
          ? "上一次恢复被中断，已保留并使用原有数据。"
          : "上一次恢复的暂存内容缺失；当前数据可正常使用。",
        databaseSchemaVersions: [:]
      )
      try writeResult(result, to: dataRoot)
      _ = unlinkat(dataRoot, markerFileName, 0)
      guard fsync(dataRoot) == 0 else { throw DesktopBackupRestoreError.restoreIncomplete }
      if let stagingRootFD = try? openDirectory(
        stagingRoot(dataDirectoryURL: dataDirectoryURL), requirePrivate: true)
      {
        removePrivateDirectory(marker.stagedDirectoryName, parent: stagingRootFD)
        Darwin.close(stagingRootFD)
      }
      if let retainedRootFD = try? openDirectory(
        retainedRoot(dataDirectoryURL: dataDirectoryURL), requirePrivate: true)
      {
        removeRetainedDirectory(marker.retainedDirectoryName, parent: retainedRootFD)
        Darwin.close(retainedRootFD)
      }
      return .failed(result)
    }
    throw DesktopBackupRestoreError.restoreIncomplete
  }

  // MARK: - Snapshot schema validation

  private static func validateSnapshotSchemas(
    in stagedDirectoryURL: URL,
    dataDirectoryURL: URL
  ) throws {
    let validationRoot = dataDirectoryURL.appendingPathComponent(
      "\(validationRootName)-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try createPrivateDirectory(validationRoot)
    defer {
      let dataRoot = Darwin.open(
        dataDirectoryURL.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      if dataRoot >= 0 {
        removePrivateDirectory(validationRoot.lastPathComponent, parent: dataRoot)
        Darwin.close(dataRoot)
      }
    }
    for name in DesktopBackupSnapshotProvider.allowedNames {
      let copyURL = validationRoot.appendingPathComponent(name, isDirectory: false)
      try copyFile(from: stagedDirectoryURL.appendingPathComponent(name), to: copyURL)
      do {
        switch name {
        case "task-events.sqlite":
          _ = try EventStore(path: copyURL.path)
        case "application.sqlite":
          _ = try ApplicationRepository(path: copyURL.path)
        case "supervision-ledger.sqlite":
          _ = try DurableSupervisionLedger(path: copyURL.path)
        default:
          throw DesktopBackupRestoreError.unsupportedSnapshotSchema(name)
        }
      } catch {
        throw DesktopBackupRestoreError.unsupportedSnapshotSchema(name)
      }
    }
  }

  private static func validateLiveStores(dataDirectoryURL: URL) throws {
    do {
      _ = try EventStore(path: dataDirectoryURL.appendingPathComponent("task-events.sqlite").path)
      _ = try ApplicationRepository(
        path: dataDirectoryURL.appendingPathComponent("application.sqlite").path)
      _ = try DurableSupervisionLedger(
        path: dataDirectoryURL.appendingPathComponent("supervision-ledger.sqlite").path)
    } catch {
      throw DesktopBackupRestoreError.invalidSnapshot
    }
  }

  private static func liveSchemaVersions(dataDirectoryURL: URL) throws -> [String: String] {
    var versions: [String: String] = [:]
    for name in DesktopBackupSnapshotProvider.allowedNames {
      let path = dataDirectoryURL.appendingPathComponent(name).path
      let queue = try DatabaseQueue(path: path, configuration: readOnlyConfiguration())
      defer { try? queue.close() }
      versions[name] = try queue.read { db in
        if try db.tableExists("grdb_migrations") {
          return try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
          ).joined(separator: ",")
        }
        if try db.tableExists("bridge_repository_meta") {
          return try Int64.fetchAll(
            db,
            sql: "SELECT schema_version FROM bridge_repository_meta WHERE singleton = 1"
          ).first.map { String($0) } ?? "unknown"
        }
        if try db.tableExists("bridge_supervision_meta") {
          return try Int64.fetchAll(
            db,
            sql: "SELECT schema_version FROM bridge_supervision_meta WHERE singleton = 1"
          ).first.map { String($0) } ?? "unknown"
        }
        return "unknown"
      }
    }
    return versions
  }

  private static func readOnlyConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(5)
    return configuration
  }

  // MARK: - Package digest

  static func packageDigest(of directoryURL: URL) throws -> String {
    let directory = try openDirectory(directoryURL, requirePrivate: true)
    defer { Darwin.close(directory) }
    var lines: [String] = []
    for name in DesktopBackupSnapshotProvider.allowedNames {
      let bytes = try readEntry(
        name, from: directory, maximumBytes: DesktopBackupPackage.maximumEntryBytes)
      lines.append("\(name):\(bytes.count):\(digest(bytes))")
    }
    return digest(Data(lines.joined(separator: "\n").utf8))
  }

  // MARK: - Marker and result persistence

  private static func writeMarker(_ marker: DesktopRestoreMarker, to dataRoot: Int32) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(marker)
    try replacePrivateFile(markerFileName, data: data, to: dataRoot)
    guard fsync(dataRoot) == 0 else { throw DesktopBackupRestoreError.markerUnavailable }
  }

  private static func readMarker(_ url: URL) throws -> DesktopRestoreMarker {
    let dataRoot = try openDirectory(url.deletingLastPathComponent(), requirePrivate: true)
    defer { Darwin.close(dataRoot) }
    let bytes = try readEntry(
      url.lastPathComponent, from: dataRoot, maximumBytes: Int64(maximumMarkerBytes))
    return try decodeMarker(bytes)
  }

  private static func decodeMarker(_ data: Data) throws -> DesktopRestoreMarker {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DesktopRestoreMarker.self, from: data)
  }

  private static func writeResult(_ result: DesktopRestoreResult, to dataRoot: Int32) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    try replacePrivateFile(resultFileName, data: data, to: dataRoot)
    guard fsync(dataRoot) == 0 else { throw DesktopBackupRestoreError.markerUnavailable }
  }

  private static func decodeResult(_ data: Data) throws -> DesktopRestoreResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DesktopRestoreResult.self, from: data)
  }

  // MARK: - Swap helpers

  private static func moveWithCompanions(name: String, from source: Int32, to destination: Int32)
    throws
  {
    for candidate in [name, name + "-wal", name + "-shm"] {
      var metadata = stat()
      if fstatat(source, candidate, &metadata, 0) == 0 {
        guard renameat(source, candidate, destination, candidate) == 0 else {
          throw DesktopBackupRestoreError.stagingUnavailable
        }
      } else if errno != ENOENT {
        throw DesktopBackupRestoreError.stagingUnavailable
      }
    }
  }

  private static func rollbackSwap(
    dataRoot: Int32,
    retained: Int32,
    staged: Int32,
    movedToLive: [String],
    movedToRetained: [String]
  ) {
    for name in movedToLive.reversed() {
      _ = renameat(dataRoot, name, staged, name)
      for suffix in ["-wal", "-shm"] {
        _ = renameat(dataRoot, name + suffix, staged, name + suffix)
      }
    }
    for name in movedToRetained.reversed() {
      _ = renameat(retained, name, dataRoot, name)
      for suffix in ["-wal", "-shm"] {
        _ = renameat(retained, name + suffix, dataRoot, name + suffix)
      }
    }
    _ = fsync(dataRoot)
    _ = fsync(staged)
    _ = fsync(retained)
  }

  private static func removeRetainedDirectory(_ name: String, parent: Int32) {
    guard let directory = try? openatDirectory(parent, name) else {
      _ = unlinkat(parent, name, AT_REMOVEDIR)
      return
    }
    for fileName in DesktopBackupSnapshotProvider.allowedNames {
      _ = unlinkat(directory, fileName, 0)
      for suffix in ["-wal", "-shm"] {
        _ = unlinkat(directory, fileName + suffix, 0)
      }
    }
    Darwin.close(directory)
    _ = unlinkat(parent, name, AT_REMOVEDIR)
  }

  // MARK: - Directory helpers

  private static func createPrivateDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw DesktopBackupRestoreError.stagingUnavailable
    }
    guard (try? openDirectory(url, requirePrivate: true)) != nil else {
      throw DesktopBackupRestoreError.stagingUnavailable
    }
  }

  static func openDirectory(_ url: URL, requirePrivate: Bool) throws -> Int32 {
    let descriptor = Darwin.open(
      url.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw DesktopBackupRestoreError.invalidDataDirectory }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      !requirePrivate || (metadata.st_mode & 0o777) == 0o700
    else {
      Darwin.close(descriptor)
      throw DesktopBackupRestoreError.invalidDataDirectory
    }
    return descriptor
  }

  private static func openatDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DesktopBackupRestoreError.invalidDataDirectory }
    return descriptor
  }

  static func removePrivateDirectory(_ name: String, parent: Int32) {
    guard let descriptor = try? openatDirectory(parent, name) else {
      _ = unlinkat(parent, name, AT_REMOVEDIR)
      return
    }
    Darwin.close(descriptor)
    _ = unlinkat(parent, name, AT_REMOVEDIR)
  }

  // MARK: - File helpers

  private static func copyPackageEntries(from packageURL: URL, to staged: Int32) throws {
    let package = Darwin.open(
      packageURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard package >= 0 else { throw DesktopBackupRestoreError.invalidPackage }
    defer { Darwin.close(package) }
    for name in DesktopBackupSnapshotProvider.allowedNames {
      let bytes = try readEntry(
        name, from: package, maximumBytes: DesktopBackupPackage.maximumEntryBytes)
      try writeEntry(bytes, name: name, to: staged)
    }
    let manifestData = try readEntry(
      DesktopBackupPackage.manifestFileName,
      from: package,
      maximumBytes: Int64(DesktopBackupPackage.maximumManifestBytes)
    )
    try writeEntry(manifestData, name: DesktopBackupPackage.manifestFileName, to: staged)
  }

  private static func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
    let source = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard source >= 0 else { throw DesktopBackupRestoreError.invalidSnapshot }
    defer { Darwin.close(source) }
    let bytes = try readAll(source, maximumBytes: DesktopBackupPackage.maximumEntryBytes)
    let parent = Darwin.open(
      destinationURL.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parent >= 0 else { throw DesktopBackupRestoreError.stagingUnavailable }
    defer { Darwin.close(parent) }
    try writeEntry(bytes, name: destinationURL.lastPathComponent, to: parent)
  }

  static func makePrivateRegularFile(_ url: URL) throws -> Bool {
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else { return false }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fsync(descriptor) == 0 else {
      return false
    }
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & 0o777) == 0o600 else {
      return false
    }
    return true
  }

  private static func replacePrivateFile(_ name: String, data: Data, to directory: Int32) throws {
    _ = unlinkat(directory, name, 0)
    try writeEntry(data, name: name, to: directory)
  }

  private static func writeEntry(_ bytes: Data, name: String, to directory: Int32) throws {
    let descriptor = openat(
      directory,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw DesktopBackupRestoreError.stagingUnavailable }
    var complete = false
    defer {
      Darwin.close(descriptor)
      if !complete { _ = unlinkat(directory, name, 0) }
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw DesktopBackupRestoreError.stagingUnavailable
    }
    try writeAll(bytes, to: descriptor)
    guard fsync(descriptor) == 0 else { throw DesktopBackupRestoreError.stagingUnavailable }
    complete = true
  }

  static func readEntry(_ name: String, from directory: Int32, maximumBytes: Int64) throws -> Data {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DesktopBackupRestoreError.invalidPackage
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o777) == 0o600,
      metadata.st_nlink == 1
    else {
      throw DesktopBackupRestoreError.invalidPackage
    }
    guard metadata.st_size <= maximumBytes else {
      throw DesktopBackupRestoreError.invalidPackage
    }
    return try readAll(descriptor, maximumBytes: maximumBytes)
  }

  private static func readAll(_ descriptor: Int32, maximumBytes: Int64) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == 0 { return data }
      if count < 0 {
        if errno == EINTR { continue }
        throw DesktopBackupRestoreError.invalidPackage
      }
      let (nextCount, overflow) = data.count.addingReportingOverflow(count)
      guard !overflow, Int64(nextCount) <= maximumBytes else {
        throw DesktopBackupRestoreError.invalidPackage
      }
      data.append(buffer, count: count)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw DesktopBackupRestoreError.stagingUnavailable }
        offset += count
      }
    }
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
