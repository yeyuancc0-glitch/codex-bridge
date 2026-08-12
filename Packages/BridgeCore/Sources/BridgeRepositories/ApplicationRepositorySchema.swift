import GRDB

enum ApplicationRepositorySchema {
  static let version: Int64 = 1
  static let migrationPrefix = "BridgeRepositories."
  static let migrationV1 = "BridgeRepositories.v1"
  static let knownMigrations: Set<String> = [migrationV1]

  static func prepare(_ database: DatabaseQueue) throws {
    do {
      try preflight(database)
      var migrator = DatabaseMigrator()
      migrator.registerMigration(migrationV1) { db in
        try createVersionOne(in: db)
      }
      try migrator.migrate(database)
      try validate(database)
    } catch let error as ApplicationRepositoryError {
      throw error
    } catch {
      throw ApplicationRepositoryError.corruptSchema
    }
  }

  private static func preflight(_ database: DatabaseQueue) throws {
    try database.read { db in
      if try db.tableExists("grdb_migrations") {
        let identifiers = try String.fetchAll(
          db,
          sql: "SELECT identifier FROM grdb_migrations WHERE identifier LIKE ?",
          arguments: [migrationPrefix + "%"]
        )
        if let unknown = identifiers.first(where: { !knownMigrations.contains($0) }) {
          throw ApplicationRepositoryError.unknownMigration(unknown)
        }
      }

      let repositoryTables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name GLOB 'bridge_repository_*'
          """
      )
      guard !repositoryTables.isEmpty else { return }
      guard try db.tableExists("bridge_repository_meta") else {
        throw ApplicationRepositoryError.corruptSchema
      }
      let versions = try Int64.fetchAll(
        db,
        sql: "SELECT schema_version FROM bridge_repository_meta WHERE singleton = 1"
      )
      guard versions.count == 1 else {
        throw ApplicationRepositoryError.corruptSchema
      }
      guard versions[0] == version else {
        throw ApplicationRepositoryError.unsupportedSchemaVersion(versions[0])
      }
    }
  }

  private static func createVersionOne(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_repository_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            schema_version INTEGER NOT NULL CHECK (schema_version > 0)
        ) WITHOUT ROWID;
        INSERT INTO bridge_repository_meta (singleton, schema_version) VALUES (1, 1);

        CREATE TABLE bridge_repository_projects (
            project_id TEXT PRIMARY KEY NOT NULL,
            configuration_json BLOB NOT NULL,
            configuration_sha256 BLOB NOT NULL,
            created_at REAL NOT NULL,
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (typeof(configuration_json) = 'blob'),
            CHECK (length(configuration_json) BETWEEN 2 AND 262144),
            CHECK (typeof(configuration_sha256) = 'blob'),
            CHECK (length(configuration_sha256) = 32)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_repository_project_roots (
            project_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('primary', 'worktree')),
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            canonical_path TEXT NOT NULL,
            device TEXT NOT NULL,
            inode TEXT NOT NULL,
            PRIMARY KEY (project_id, role, ordinal),
            UNIQUE (canonical_path),
            UNIQUE (device, inode),
            UNIQUE (project_id, canonical_path, device, inode),
            FOREIGN KEY (project_id)
              REFERENCES bridge_repository_projects(project_id) ON DELETE RESTRICT,
            CHECK (length(CAST(canonical_path AS BLOB)) BETWEEN 1 AND 16384),
            CHECK (length(device) BETWEEN 1 AND 20),
            CHECK (length(inode) BETWEEN 1 AND 20),
            CHECK (role != 'primary' OR ordinal = 0)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_repository_thread_bindings (
            thread_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            canonical_path TEXT NOT NULL,
            device TEXT NOT NULL,
            inode TEXT NOT NULL,
            bound_at REAL NOT NULL,
            FOREIGN KEY (project_id)
              REFERENCES bridge_repository_projects(project_id) ON DELETE RESTRICT,
            FOREIGN KEY (project_id, canonical_path, device, inode)
              REFERENCES bridge_repository_project_roots(
                project_id, canonical_path, device, inode
              ) ON DELETE RESTRICT,
            CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 1024)
        ) WITHOUT ROWID;

        CREATE INDEX bridge_repository_thread_project
        ON bridge_repository_thread_bindings(project_id, thread_id);

        CREATE TABLE bridge_repository_final_reports (
            task_id TEXT PRIMARY KEY NOT NULL,
            schema_version INTEGER NOT NULL CHECK (schema_version BETWEEN 1 AND 65535),
            status TEXT NOT NULL CHECK (status IN ('completed', 'failed', 'interrupted', 'rejected')),
            project_name TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            stored_at REAL NOT NULL,
            report_json BLOB NOT NULL,
            report_sha256 BLOB NOT NULL,
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(project_name AS BLOB)) BETWEEN 1 AND 16384),
            CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (typeof(report_json) = 'blob'),
            CHECK (length(report_json) BETWEEN 2 AND 262144),
            CHECK (typeof(report_sha256) = 'blob'),
            CHECK (length(report_sha256) = 32)
        ) WITHOUT ROWID;
        """)
  }

  private static func validate(_ database: DatabaseQueue) throws {
    try database.read { db in
      let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
      guard quickCheck == "ok" else { throw ApplicationRepositoryError.corruptSchema }
      let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
      guard foreignKeyFailures.isEmpty else {
        throw ApplicationRepositoryError.corruptSchema
      }

      let version = try Int64.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_repository_meta WHERE singleton = 1"
      )
      guard let version else { throw ApplicationRepositoryError.corruptSchema }
      guard version == self.version else {
        throw ApplicationRepositoryError.unsupportedSchemaVersion(version)
      }

      let requiredTables = [
        "bridge_repository_meta",
        "bridge_repository_projects",
        "bridge_repository_project_roots",
        "bridge_repository_thread_bindings",
        "bridge_repository_final_reports",
      ]
      for table in requiredTables where try !db.tableExists(table) {
        throw ApplicationRepositoryError.corruptSchema
      }

      let requiredColumns: [String: Set<String>] = [
        "bridge_repository_meta": ["singleton", "schema_version"],
        "bridge_repository_projects": [
          "project_id", "configuration_json", "configuration_sha256", "created_at",
        ],
        "bridge_repository_project_roots": [
          "project_id", "role", "ordinal", "canonical_path", "device", "inode",
        ],
        "bridge_repository_thread_bindings": [
          "thread_id", "project_id", "canonical_path", "device", "inode", "bound_at",
        ],
        "bridge_repository_final_reports": [
          "task_id", "schema_version", "status", "project_name", "thread_id", "stored_at",
          "report_json", "report_sha256",
        ],
      ]
      for (table, expected) in requiredColumns {
        let actual = Set(try db.columns(in: table).map(\.name))
        guard actual == expected else { throw ApplicationRepositoryError.corruptSchema }
      }
    }
  }
}
