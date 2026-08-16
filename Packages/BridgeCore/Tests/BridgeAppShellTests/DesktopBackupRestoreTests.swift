import BridgePersistence
import BridgePipeline
import BridgeRepositories
import Darwin
import Foundation
import GRDB
import XCTest

@testable import BridgeAppShell

final class DesktopBackupRestoreTests: XCTestCase {
  // MARK: - Online consistency and round trip

  func testSnapshotWhileWritingProducesConsistentRestorableBackup() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let stores = try makeStores(data: fixture.data)
    try writeMarker("event-original", to: fixture.data.appendingPathComponent("task-events.sqlite"))
    try writeMarker("app-original", to: fixture.data.appendingPathComponent("application.sqlite"))
    try writeMarker(
      "supervision-original", to: fixture.data.appendingPathComponent("supervision-ledger.sqlite"))

    let writer = DispatchQueue(label: "bridge-backup-writer")
    let writerStarted = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    writer.async { [fixture] in
      guard
        let queue = try? DatabaseQueue(
          path: fixture.data.appendingPathComponent("task-events.sqlite").path
        )
      else {
        writerFinished.signal()
        return
      }
      try? queue.write { db in
        try? db.execute(sql: "INSERT INTO _backup_restore_marker (value) VALUES ('writer-a')")
        writerStarted.signal()
        Thread.sleep(forTimeInterval: 0.2)
        try? db.execute(sql: "INSERT INTO _backup_restore_marker (value) VALUES ('writer-b')")
      }
      writerFinished.signal()
    }
    writerStarted.wait()
    // Snapshot while the writer transaction is in flight.
    let snapshot = try DesktopBackupSnapshotProvider.makeSnapshotDirectory(
      dataDirectoryURL: fixture.data)
    defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
    writerFinished.wait()

    XCTAssertEqual(snapshot.summary.databases.count, 3)
    XCTAssertEqual(
      Set(snapshot.summary.databases.map(\.name)),
      DesktopBackupPackage.allowedEntryNames
    )
    for database in snapshot.summary.databases {
      XCTAssertFalse(database.sha256.isEmpty)
      XCTAssertFalse(database.schemaVersion.isEmpty)
    }

    let package = fixture.root.appendingPathComponent("CodexBridge.backup", isDirectory: true)
    _ = try DesktopBackupPackage.create(from: snapshot.directoryURL, at: package)
    _ = try DesktopBackupPackage.validate(at: package)

    _ = try DesktopRestoreCoordinator.prepareRestore(
      packageURL: package,
      dataDirectoryURL: fixture.data
    )
    XCTAssertTrue(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))

    let outcome = try DesktopRestoreCoordinator.performPendingRestoreIfNeeded(
      dataDirectoryURL: fixture.data
    )
    guard case .succeeded(let result) = outcome else {
      return XCTFail("Expected successful restore, got \(outcome)")
    }
    XCTAssertEqual(result.status, .succeeded)
    XCTAssertFalse(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))
    XCTAssertEqual(result.databaseSchemaVersions.count, 3)

    // The restored live stores still contain the original snapshot markers and open cleanly.
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("task-events.sqlite")),
      "event-original"
    )
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("application.sqlite")),
      "app-original"
    )
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("supervision-ledger.sqlite")),
      "supervision-original"
    )
    _ = try EventStore(path: fixture.data.appendingPathComponent("task-events.sqlite").path)
    _ = try ApplicationRepository(
      path: fixture.data.appendingPathComponent("application.sqlite").path)
    _ = try DurableSupervisionLedger(
      path: fixture.data.appendingPathComponent("supervision-ledger.sqlite").path)
    _ = stores
  }

  // MARK: - Fail-closed staging validation

  func testPrepareRestoreRejectsSecondPendingRestore() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    let package = try makePackage(fixture: fixture)
    _ = try DesktopRestoreCoordinator.prepareRestore(
      packageURL: package,
      dataDirectoryURL: fixture.data
    )
    XCTAssertTrue(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))

    XCTAssertThrowsError(
      try DesktopRestoreCoordinator.prepareRestore(
        packageURL: package,
        dataDirectoryURL: fixture.data
      )
    ) { error in
      XCTAssertEqual(error as? DesktopBackupRestoreError, .restoreAlreadyPending)
    }
  }

  func testPrepareRestoreRejectsTamperedPackageAndPreservesData() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    try writeMarker("original", to: fixture.data.appendingPathComponent("application.sqlite"))
    let package = try makePackage(fixture: fixture)

    let entry = package.appendingPathComponent("application.sqlite")
    try Data("tampered".utf8).write(to: entry)
    chmod(entry.path, S_IRUSR | S_IWUSR)

    XCTAssertThrowsError(
      try DesktopRestoreCoordinator.prepareRestore(
        packageURL: package,
        dataDirectoryURL: fixture.data
      )
    ) { error in
      XCTAssertEqual(
        error as? DesktopBackupPackageError,
        .digestMismatch("application.sqlite")
      )
    }
    XCTAssertFalse(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("application.sqlite")),
      "original"
    )
  }

  func testPrepareRestoreRejectsUnsupportedSnapshotSchema() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)

    // Build a package whose task-events.sqlite is a valid SQLite file but the wrong schema.
    let source = fixture.root.appendingPathComponent("PackageSource", isDirectory: true)
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    for name in DesktopBackupPackage.allowedEntryNames.sorted() {
      let bytes =
        name == "task-events.sqlite"
        ? Data("not-a-bridge-schema".utf8)
        : try readMarkerFile(fixture.data.appendingPathComponent(name))
      let url = source.appendingPathComponent(name)
      try bytes.write(to: url)
      chmod(url.path, S_IRUSR | S_IWUSR)
    }
    let package = fixture.root.appendingPathComponent("Wrong.backup", isDirectory: true)
    _ = try DesktopBackupPackage.create(from: source, at: package)

    XCTAssertThrowsError(
      try DesktopRestoreCoordinator.prepareRestore(
        packageURL: package,
        dataDirectoryURL: fixture.data
      )
    ) { error in
      XCTAssertEqual(
        error as? DesktopBackupRestoreError,
        .unsupportedSnapshotSchema("task-events.sqlite")
      )
    }
    XCTAssertFalse(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))
  }

  // MARK: - Crash recovery and identity drift

  func testPerformRestoreRejectsDataRootDrift() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    let package = try makePackage(fixture: fixture)
    let marker = try DesktopRestoreCoordinator.prepareRestore(
      packageURL: package,
      dataDirectoryURL: fixture.data
    )

    // Replace the data root with a fresh directory that still carries the marker.
    let moved = fixture.root.appendingPathComponent("Data-old", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.data, to: moved)
    try FileManager.default.createDirectory(
      at: fixture.data,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let markerData = try Data(
      contentsOf: moved.appendingPathComponent(DesktopRestoreCoordinator.markerFileName))
    try markerData.write(
      to: fixture.data.appendingPathComponent(DesktopRestoreCoordinator.markerFileName))
    chmod(
      fixture.data.appendingPathComponent(DesktopRestoreCoordinator.markerFileName).path,
      S_IRUSR | S_IWUSR)

    XCTAssertThrowsError(
      try DesktopRestoreCoordinator.performPendingRestoreIfNeeded(dataDirectoryURL: fixture.data)
    ) { error in
      XCTAssertEqual(error as? DesktopBackupRestoreError, .dataRootDrift)
    }
    XCTAssertEqual(
      DesktopRestoreCoordinator.latestResult(dataDirectoryURL: fixture.data)?.status,
      .failed
    )
    _ = marker
  }

  func testPerformRestoreRecoversWhenStagingMissingBeforeSwap() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    try writeMarker("original", to: fixture.data.appendingPathComponent("task-events.sqlite"))
    let package = try makePackage(fixture: fixture)
    let marker = try DesktopRestoreCoordinator.prepareRestore(
      packageURL: package,
      dataDirectoryURL: fixture.data
    )
    try FileManager.default.removeItem(
      at: DesktopRestoreCoordinator.stagingRoot(dataDirectoryURL: fixture.data)
    )

    let outcome = try DesktopRestoreCoordinator.performPendingRestoreIfNeeded(
      dataDirectoryURL: fixture.data
    )
    guard case .failed(let result) = outcome else {
      return XCTFail("Expected failed recovery, got \(outcome)")
    }
    XCTAssertTrue(result.message.contains("暂存内容缺失"))
    XCTAssertFalse(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("task-events.sqlite")),
      "original"
    )
    _ = marker
  }

  func testPerformRestoreRecoversWhenSwapInterruptedWithRetainedData() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    try writeMarker("original", to: fixture.data.appendingPathComponent("task-events.sqlite"))
    let package = try makePackage(fixture: fixture)
    let marker = try DesktopRestoreCoordinator.prepareRestore(
      packageURL: package,
      dataDirectoryURL: fixture.data
    )

    // Simulate a crash after the swap moved live -> retained and staged -> live.
    let retainedRoot = DesktopRestoreCoordinator.retainedRoot(dataDirectoryURL: fixture.data)
    let retainedDirectory = retainedRoot.appendingPathComponent(
      marker.retainedDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: retainedRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try FileManager.default.createDirectory(
      at: retainedDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let stagedDirectory = DesktopRestoreCoordinator.stagingRoot(dataDirectoryURL: fixture.data)
      .appendingPathComponent(marker.stagedDirectoryName, isDirectory: true)
    for name in DesktopBackupPackage.allowedEntryNames.sorted() {
      try FileManager.default.moveItem(
        at: fixture.data.appendingPathComponent(name),
        to: retainedDirectory.appendingPathComponent(name)
      )
    }
    for name in DesktopBackupPackage.allowedEntryNames.sorted() {
      try FileManager.default.moveItem(
        at: stagedDirectory.appendingPathComponent(name),
        to: fixture.data.appendingPathComponent(name)
      )
    }

    let outcome = try DesktopRestoreCoordinator.performPendingRestoreIfNeeded(
      dataDirectoryURL: fixture.data
    )
    guard case .failed(let result) = outcome else {
      return XCTFail("Expected failed recovery, got \(outcome)")
    }
    XCTAssertTrue(result.message.contains("已保留并使用原有数据"))
    XCTAssertFalse(DesktopRestoreCoordinator.pendingMarkerExists(dataDirectoryURL: fixture.data))
    XCTAssertEqual(
      try readMarker(from: fixture.data.appendingPathComponent("task-events.sqlite")),
      "original"
    )
  }

  // MARK: - Sensitive content and permissions

  func testSnapshotAndPackageExcludeSensitiveFiles() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    // Non-package content that must never enter a backup.
    let supervisorHome = fixture.data.appendingPathComponent("supervisor-home", isDirectory: true)
    try FileManager.default.createDirectory(at: supervisorHome, withIntermediateDirectories: false)
    try Data("auth".utf8).write(to: supervisorHome.appendingPathComponent("auth.json"))
    try Data("log".utf8).write(to: fixture.data.appendingPathComponent("diagnostics.log"))

    let snapshot = try DesktopBackupSnapshotProvider.makeSnapshotDirectory(
      dataDirectoryURL: fixture.data)
    defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
    let children = try FileManager.default.contentsOfDirectory(atPath: snapshot.directoryURL.path)
    XCTAssertEqual(Set(children), DesktopBackupPackage.allowedEntryNames)
    for name in children {
      XCTAssertNotEqual(name, "supervisor-home")
      XCTAssertNotEqual(name, "diagnostics.log")
    }

    let package = fixture.root.appendingPathComponent("CodexBridge.backup", isDirectory: true)
    _ = try DesktopBackupPackage.create(from: snapshot.directoryURL, at: package)
    let packageChildren = try FileManager.default.contentsOfDirectory(atPath: package.path)
    XCTAssertEqual(
      Set(packageChildren),
      DesktopBackupPackage.allowedEntryNames.union([DesktopBackupPackage.manifestFileName])
    )
    _ = try DesktopBackupPackage.validate(at: package)
  }

  func testSnapshotRejectsPermissiveDataRoot() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try makeStores(data: fixture.data)
    chmod(fixture.data.path, S_IRWXU | S_IRGRP | S_IXGRP)

    XCTAssertThrowsError(
      try DesktopBackupSnapshotProvider.makeSnapshotDirectory(dataDirectoryURL: fixture.data)
    ) { error in
      XCTAssertEqual(error as? DesktopBackupRestoreError, .invalidDataDirectory)
    }
  }

  // MARK: - Helpers

  private func makeStores(data: URL) throws -> (
    EventStore, ApplicationRepository, DurableSupervisionLedger
  ) {
    (
      try EventStore(path: data.appendingPathComponent("task-events.sqlite").path),
      try ApplicationRepository(path: data.appendingPathComponent("application.sqlite").path),
      try DurableSupervisionLedger(
        path: data.appendingPathComponent("supervision-ledger.sqlite").path)
    )
  }

  private func makePackage(fixture: RestoreFixture) throws -> URL {
    let snapshot = try DesktopBackupSnapshotProvider.makeSnapshotDirectory(
      dataDirectoryURL: fixture.data
    )
    defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
    let package = fixture.root.appendingPathComponent("CodexBridge.backup", isDirectory: true)
    _ = try DesktopBackupPackage.create(from: snapshot.directoryURL, at: package)
    return package
  }

  private func writeMarker(_ value: String, to fileURL: URL) throws {
    let queue = try DatabaseQueue(path: fileURL.path)
    defer { try? queue.close() }
    try queue.write { db in
      try db.execute(
        sql: "CREATE TABLE IF NOT EXISTS _backup_restore_marker (value TEXT NOT NULL)"
      )
      try db.execute(sql: "DELETE FROM _backup_restore_marker")
      try db.execute(
        sql: "INSERT INTO _backup_restore_marker (value) VALUES (?)", arguments: [value])
    }
  }

  private func readMarker(from fileURL: URL) throws -> String? {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
    defer { try? queue.close() }
    return try queue.read { db in
      guard try db.tableExists("_backup_restore_marker") else { return nil }
      return try String.fetchOne(db, sql: "SELECT value FROM _backup_restore_marker")
    }
  }

  private func readMarkerFile(_ url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  private func makeFixture() throws -> RestoreFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-backup-restore-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let data = root.appendingPathComponent("Data", isDirectory: true)
    try FileManager.default.createDirectory(
      at: data,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return RestoreFixture(root: root, data: data)
  }
}

private struct RestoreFixture {
  let root: URL
  let data: URL
}
