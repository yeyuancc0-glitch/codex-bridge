import CryptoKit
import Darwin
import Foundation
import GRDB

public enum DatabaseMigrationBackupError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case insecureParentDirectory
  case backupUnavailable
  case corruptBackup
}

public enum DatabaseMigrationBackup {
  @discardableResult
  public static func createIfNeeded(
    database: DatabaseQueue,
    knownMigrationIdentifiers: [String],
    componentIdentifier: String
  ) throws -> URL? {
    try validate(
      migrationIdentifiers: knownMigrationIdentifiers,
      componentIdentifier: componentIdentifier
    )
    guard database.path != ":memory:" else { return nil }
    guard try requiresBackup(database, knownMigrationIdentifiers) else { return nil }

    let destination = try backupURL(
      databasePath: database.path,
      componentIdentifier: componentIdentifier
    )
    let parent = destination.deletingLastPathComponent()
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else {
      throw DatabaseMigrationBackupError.insecureParentDirectory
    }
    defer { Darwin.close(parentDescriptor) }
    try validateParentDirectory(parentDescriptor)

    let temporaryName = ".codex-bridge-migration-\(UUID().uuidString).sqlite"
    try createEmptyFile(temporaryName, in: parentDescriptor)
    var published = false
    defer {
      if !published {
        removeTemporaryFiles(temporaryName, from: parentDescriptor)
      }
    }

    let temporaryURL = parent.appending(path: temporaryName)
    try copy(database, to: temporaryURL)
    removeTemporaryCompanionFiles(temporaryName, from: parentDescriptor)
    try validateAndSynchronize(temporaryName, in: parentDescriptor)
    guard
      renameat(
        parentDescriptor,
        temporaryName,
        parentDescriptor,
        destination.lastPathComponent
      ) == 0,
      fsync(parentDescriptor) == 0
    else {
      throw DatabaseMigrationBackupError.backupUnavailable
    }
    published = true
    return destination
  }

  public static func backupURL(
    databasePath: String,
    componentIdentifier: String
  ) throws -> URL {
    guard databasePath != ":memory:", !databasePath.isEmpty, !databasePath.contains("\0") else {
      throw DatabaseMigrationBackupError.invalidArgument("databasePath")
    }
    try validateComponentIdentifier(componentIdentifier)
    let databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
    let pathDigest = SHA256.hash(data: Data(databaseURL.path.utf8))
      .prefix(12)
      .map { String(format: "%02x", $0) }
      .joined()
    let name = ".codex-bridge-\(componentIdentifier)-\(pathDigest).pre-migration.sqlite"
    return databaseURL.deletingLastPathComponent().appending(path: name)
  }

  private static func requiresBackup(
    _ database: DatabaseQueue,
    _ knownMigrationIdentifiers: [String]
  ) throws -> Bool {
    try database.read { db in
      guard try db.tableExists("grdb_migrations") else { return false }
      let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
      let relevantCount = knownMigrationIdentifiers.reduce(into: 0) { count, identifier in
        if applied.contains(identifier) { count += 1 }
      }
      return relevantCount > 0 && relevantCount < knownMigrationIdentifiers.count
    }
  }

  private static func copy(_ source: DatabaseQueue, to destinationURL: URL) throws {
    let destination: DatabaseQueue
    do {
      destination = try DatabaseQueue(path: destinationURL.path)
    } catch {
      throw DatabaseMigrationBackupError.backupUnavailable
    }
    do {
      try source.backup(to: destination)
      let journalMode = try destination.writeWithoutTransaction { db in
        try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
      }
      guard journalMode?.lowercased() == "delete" else {
        throw DatabaseMigrationBackupError.corruptBackup
      }
      let quickCheck = try destination.read { db in
        try String.fetchAll(db, sql: "PRAGMA quick_check(1)")
      }
      guard quickCheck == ["ok"] else {
        throw DatabaseMigrationBackupError.corruptBackup
      }
      try destination.close()
    } catch let error as DatabaseMigrationBackupError {
      try? destination.close()
      throw error
    } catch {
      try? destination.close()
      throw DatabaseMigrationBackupError.backupUnavailable
    }
  }

  private static func validate(
    migrationIdentifiers: [String],
    componentIdentifier: String
  ) throws {
    guard !migrationIdentifiers.isEmpty,
      Set(migrationIdentifiers).count == migrationIdentifiers.count
    else {
      throw DatabaseMigrationBackupError.invalidArgument("knownMigrationIdentifiers")
    }
    for identifier in migrationIdentifiers {
      guard !identifier.isEmpty, identifier.utf8.count <= 256, !identifier.contains("\0") else {
        throw DatabaseMigrationBackupError.invalidArgument("knownMigrationIdentifiers")
      }
    }
    try validateComponentIdentifier(componentIdentifier)
  }

  private static func validateComponentIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 64,
      value.utf8.allSatisfy(isPermittedComponentByte)
    else {
      throw DatabaseMigrationBackupError.invalidArgument("componentIdentifier")
    }
  }

  private static func isPermittedComponentByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      || byte == 45 || byte == 46 || byte == 95
  }

  private static func validateParentDirectory(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(), (metadata.st_mode & 0o777) == 0o700
    else {
      throw DatabaseMigrationBackupError.insecureParentDirectory
    }
  }

  private static func createEmptyFile(_ name: String, in parent: Int32) throws {
    let descriptor = openat(
      parent,
      name,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw DatabaseMigrationBackupError.backupUnavailable }
    guard Darwin.close(descriptor) == 0 else {
      _ = unlinkat(parent, name, 0)
      throw DatabaseMigrationBackupError.backupUnavailable
    }
  }

  private static func validateAndSynchronize(_ name: String, in parent: Int32) throws {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DatabaseMigrationBackupError.backupUnavailable }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(), (metadata.st_mode & 0o777) == 0o600,
      metadata.st_size > 0
    else {
      throw DatabaseMigrationBackupError.corruptBackup
    }
    guard fsync(descriptor) == 0 else {
      throw DatabaseMigrationBackupError.backupUnavailable
    }
  }

  private static func removeTemporaryFiles(_ name: String, from parent: Int32) {
    _ = unlinkat(parent, name, 0)
    removeTemporaryCompanionFiles(name, from: parent)
  }

  private static func removeTemporaryCompanionFiles(_ name: String, from parent: Int32) {
    for suffix in ["-journal", "-wal", "-shm"] {
      _ = unlinkat(parent, name + suffix, 0)
    }
  }
}
