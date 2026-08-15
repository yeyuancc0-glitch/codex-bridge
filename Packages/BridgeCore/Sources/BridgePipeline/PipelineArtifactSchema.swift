import BridgePersistence
import GRDB

enum PipelineArtifactSchema {
  static let version: Int64 = 1
  static let migrationPrefix = "BridgePipeline."
  static let migrationV1 = "BridgePipeline.v1"
  static let knownMigrations: Set<String> = [migrationV1]
  static let migrationIdentifiers = [migrationV1]

  static func prepare(_ database: DatabaseQueue) throws {
    do {
      try preflight(database)
      let migrator = makeMigrator()
      try DatabaseMigrationBackup.createIfNeeded(
        database: database,
        knownMigrationIdentifiers: migrationIdentifiers,
        componentIdentifier: "BridgePipeline"
      )
      try migrator.migrate(database)
      try validate(database)
    } catch let error as PipelineArtifactStoreError {
      throw error
    } catch {
      throw PipelineArtifactStoreError.corruptSchema
    }
  }

  static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(migrationV1) { db in
      try createVersionOne(in: db)
    }
    return migrator
  }

  private static func preflight(_ database: DatabaseQueue) throws {
    try database.read { db in
      if try db.tableExists("grdb_migrations") {
        let migrations = try String.fetchAll(
          db,
          sql: "SELECT identifier FROM grdb_migrations WHERE identifier LIKE ?",
          arguments: [migrationPrefix + "%"]
        )
        if let unknown = migrations.first(where: { !knownMigrations.contains($0) }) {
          throw PipelineArtifactStoreError.unknownMigration(unknown)
        }
      }

      let tables = try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name GLOB 'bridge_pipeline_*'"
      )
      guard !tables.isEmpty else { return }
      guard try db.tableExists("bridge_pipeline_meta") else {
        throw PipelineArtifactStoreError.corruptSchema
      }
      let versions = try Int64.fetchAll(
        db,
        sql: "SELECT schema_version FROM bridge_pipeline_meta WHERE singleton = 1"
      )
      guard versions.count == 1 else { throw PipelineArtifactStoreError.corruptSchema }
      guard versions[0] == version else {
        throw PipelineArtifactStoreError.unsupportedSchemaVersion(versions[0])
      }
    }
  }

  private static func createVersionOne(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_pipeline_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            schema_version INTEGER NOT NULL CHECK (schema_version > 0)
        ) WITHOUT ROWID;
        INSERT INTO bridge_pipeline_meta (singleton, schema_version) VALUES (1, 1);

        CREATE TABLE bridge_pipeline_scopes (
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            event_sequence INTEGER NOT NULL CHECK (event_sequence > 0),
            stage TEXT NOT NULL CHECK (stage IN (
              'created', 'baseline_captured', 'turn_completed', 'git_final_captured',
              'verification_completed', 'supervisor_reviewed', 'report_stored',
              'completed', 'failed', 'superseded'
            )),
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            updated_at REAL NOT NULL CHECK (typeof(updated_at) IN ('integer', 'real')),
            PRIMARY KEY (task_id, generation),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (length(CAST(turn_id AS BLOB)) BETWEEN 1 AND 1024)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_pipeline_current_scopes (
            task_id TEXT PRIMARY KEY NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            FOREIGN KEY (task_id, generation)
              REFERENCES bridge_pipeline_scopes(task_id, generation) ON DELETE RESTRICT
        ) WITHOUT ROWID;

        CREATE TABLE bridge_pipeline_artifacts (
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            kind_category TEXT NOT NULL CHECK (kind_category IN (
              'git_baseline', 'git_final', 'verification', 'supervisor_final', 'report_metadata'
            )),
            kind_key TEXT NOT NULL,
            schema_version INTEGER NOT NULL CHECK (schema_version BETWEEN 1 AND 65535),
            payload_json BLOB NOT NULL,
            payload_sha256 BLOB NOT NULL,
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            PRIMARY KEY (task_id, generation, kind_category, kind_key),
            FOREIGN KEY (task_id, generation)
              REFERENCES bridge_pipeline_scopes(task_id, generation) ON DELETE RESTRICT,
            CHECK (
              (kind_category = 'verification' AND length(kind_key) BETWEEN 1 AND 256)
              OR (kind_category != 'verification' AND kind_key = '')
            ),
            CHECK (typeof(payload_json) = 'blob'),
            CHECK (length(payload_json) BETWEEN 2 AND 524288),
            CHECK (typeof(payload_sha256) = 'blob'),
            CHECK (length(payload_sha256) = 32)
        ) WITHOUT ROWID;

        CREATE INDEX bridge_pipeline_pending_stage
        ON bridge_pipeline_scopes(stage, updated_at, task_id, generation);
        """
    )
  }

  private static func validate(_ database: DatabaseQueue) throws {
    try database.read { db in
      guard
        try Int64.fetchOne(
          db,
          sql: "SELECT schema_version FROM bridge_pipeline_meta WHERE singleton = 1"
        ) == version
      else { throw PipelineArtifactStoreError.corruptSchema }

      let expected: [String: Set<String>] = [
        "bridge_pipeline_meta": ["singleton", "schema_version"],
        "bridge_pipeline_scopes": [
          "task_id", "generation", "project_id", "thread_id", "turn_id", "event_sequence",
          "stage", "created_at", "updated_at",
        ],
        "bridge_pipeline_current_scopes": ["task_id", "generation"],
        "bridge_pipeline_artifacts": [
          "task_id", "generation", "kind_category", "kind_key", "schema_version",
          "payload_json", "payload_sha256", "created_at",
        ],
      ]
      for (table, columns) in expected {
        guard try db.tableExists(table), Set(try db.columns(in: table).map(\.name)) == columns
        else { throw PipelineArtifactStoreError.corruptSchema }
      }
    }
  }
}
