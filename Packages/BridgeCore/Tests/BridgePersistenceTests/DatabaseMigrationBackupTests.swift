import Darwin
import Foundation
import GRDB
import XCTest

@testable import BridgePersistence

final class DatabaseMigrationBackupTests: XCTestCase {
  func testOnlineBackupCapturesLastAppliedVersionAndIsNotOverwrittenWhenCurrent() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var configuration = Configuration()
    configuration.journalMode = .wal
    let source = try DatabaseQueue(path: fixture.database.path, configuration: configuration)
    let migrator = makeMigrator()

    XCTAssertNil(
      try DatabaseMigrationBackup.createIfNeeded(
        database: source,
        knownMigrationIdentifiers: ["test.v1", "test.v2"],
        componentIdentifier: "TestComponent"
      )
    )

    try migrator.migrate(source, upTo: "test.v1")
    try source.write { db in
      try db.execute(sql: "INSERT INTO migration_records (value) VALUES ('before')")
    }
    let expectedBackupURL = try DatabaseMigrationBackup.backupURL(
      databasePath: fixture.database.path,
      componentIdentifier: "TestComponent"
    )
    let victimURL = fixture.directory.appending(path: "must-not-be-overwritten.txt")
    try Data("unchanged".utf8).write(to: victimURL)
    try FileManager.default.createSymbolicLink(
      at: expectedBackupURL,
      withDestinationURL: victimURL
    )
    let backupURL = try XCTUnwrap(
      DatabaseMigrationBackup.createIfNeeded(
        database: source,
        knownMigrationIdentifiers: ["test.v1", "test.v2"],
        componentIdentifier: "TestComponent"
      )
    )
    XCTAssertEqual(
      backupURL,
      expectedBackupURL
    )
    XCTAssertEqual(try permissions(of: backupURL), 0o600)
    XCTAssertEqual(try Data(contentsOf: victimURL), Data("unchanged".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path + "-shm"))

    try migrator.migrate(source)
    try source.write { db in
      try db.execute(sql: "INSERT INTO migration_records (value) VALUES ('after')")
    }
    XCTAssertNil(
      try DatabaseMigrationBackup.createIfNeeded(
        database: source,
        knownMigrationIdentifiers: ["test.v1", "test.v2"],
        componentIdentifier: "TestComponent"
      )
    )

    let backup = try DatabaseQueue(path: backupURL.path)
    let values = try backup.read { db in
      try String.fetchAll(db, sql: "SELECT value FROM migration_records ORDER BY value")
    }
    let columns = try backup.read { db in
      try Set(db.columns(in: "migration_records").map(\.name))
    }
    let migrations = try backup.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    XCTAssertEqual(values, ["before"])
    XCTAssertEqual(columns, Set(["id", "value"]))
    XCTAssertEqual(migrations, ["test.v1"])
  }

  func testEventStorePublishesConsistentBackupBeforeLegacyMigration() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacy = try DatabaseQueue(path: fixture.database.path)
    try EventStoreSchema.makeMigrator().migrate(
      legacy,
      upTo: EventStoreSchema.migrationIdentifiers[0]
    )
    try await legacy.write { db in
      try db.execute(
        sql: """
          INSERT INTO tasks (task_id, last_event_seq, created_at, updated_at)
          VALUES ('legacy-task', 1, 10, 11)
          """)
      try db.execute(
        sql: """
          INSERT INTO task_events (
              task_id, seq, schema_version, source, kind, severity, payload, created_at
          ) VALUES ('legacy-task', 1, 1, 'test', 'task.created', 'info', X'7B7D', 11)
          """)
    }
    try legacy.close()

    let migrated = try EventStore(path: fixture.database.path)
    let lastSequence = try await migrated.lastEventSequence(for: .init(rawValue: "legacy-task"))
    XCTAssertEqual(lastSequence, 1)

    let backupURL = try DatabaseMigrationBackup.backupURL(
      databasePath: fixture.database.path,
      componentIdentifier: "BridgePersistence"
    )
    let backup = try DatabaseQueue(path: backupURL.path)
    let kind = try await backup.read { db in
      try String.fetchOne(db, sql: "SELECT kind FROM task_events WHERE task_id = 'legacy-task'")
    }
    let hasSnapshotTable = try await backup.read { db in
      try db.tableExists("task_state_snapshots")
    }
    let current = try DatabaseQueue(path: fixture.database.path)
    let currentHasSnapshotTable = try await current.read { db in
      try db.tableExists("task_state_snapshots")
    }
    XCTAssertEqual(kind, "task.created")
    XCTAssertFalse(hasSnapshotTable)
    XCTAssertTrue(currentHasSnapshotTable)
    XCTAssertEqual(try permissions(of: backupURL), 0o600)
  }

  func testInsecureParentStopsMigrationBeforeSchemaMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacy = try DatabaseQueue(path: fixture.database.path)
    try EventStoreSchema.makeMigrator().migrate(
      legacy,
      upTo: EventStoreSchema.migrationIdentifiers[0]
    )
    try legacy.close()
    XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)

    XCTAssertThrowsError(try EventStore(path: fixture.database.path)) { error in
      XCTAssertEqual(
        error as? DatabaseMigrationBackupError,
        .insecureParentDirectory
      )
    }
    let unchanged = try DatabaseQueue(path: fixture.database.path)
    let hasSnapshotTable = try unchanged.read { db in
      try db.tableExists("task_state_snapshots")
    }
    XCTAssertFalse(hasSnapshotTable)
  }

  private func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("test.v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE migration_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              value TEXT NOT NULL
          )
          """)
    }
    migrator.registerMigration("test.v2") { db in
      try db.execute(sql: "ALTER TABLE migration_records ADD COLUMN note TEXT")
    }
    return migrator
  }

  private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "codex-bridge-migration-backup-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    guard chmod(directory.path, 0o700) == 0 else {
      throw DatabaseMigrationBackupError.insecureParentDirectory
    }
    return Fixture(
      directory: directory,
      database: directory.appending(path: "bridge.sqlite")
    )
  }

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}

private struct Fixture {
  let directory: URL
  let database: URL
}
