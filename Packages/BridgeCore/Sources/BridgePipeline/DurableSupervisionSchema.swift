import GRDB

enum DurableSupervisionSchema {
  static let version: Int64 = 1
  static let migrationPrefix = "BridgeSupervision."
  static let migrationV1 = "BridgeSupervision.v1"
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
    } catch let error as DurableSupervisionLedgerError {
      throw error
    } catch {
      throw DurableSupervisionLedgerError.corruptSchema
    }
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
          throw DurableSupervisionLedgerError.unknownMigration(unknown)
        }
      }
      let tables = try String.fetchAll(
        db,
        sql:
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name GLOB 'bridge_supervision_*'"
      )
      guard !tables.isEmpty else { return }
      guard try db.tableExists("bridge_supervision_meta") else {
        throw DurableSupervisionLedgerError.corruptSchema
      }
      let versions = try Int64.fetchAll(
        db,
        sql: "SELECT schema_version FROM bridge_supervision_meta WHERE singleton = 1"
      )
      guard versions.count == 1 else { throw DurableSupervisionLedgerError.corruptSchema }
      guard versions[0] == version else {
        throw DurableSupervisionLedgerError.unsupportedSchemaVersion(versions[0])
      }
    }
  }

  private static func createVersionOne(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_supervision_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            schema_version INTEGER NOT NULL CHECK (schema_version > 0)
        ) WITHOUT ROWID;
        INSERT INTO bridge_supervision_meta (singleton, schema_version) VALUES (1, 1);

        CREATE TABLE bridge_supervision_scopes (
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'superseded')),
            configuration_json BLOB NOT NULL,
            configuration_sha256 BLOB NOT NULL CHECK (length(configuration_sha256) = 32),
            reducer_state_json BLOB NOT NULL,
            reducer_state_sha256 BLOB NOT NULL CHECK (length(reducer_state_sha256) = 32),
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            updated_at REAL NOT NULL CHECK (typeof(updated_at) IN ('integer', 'real')),
            PRIMARY KEY (task_id, generation),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (length(CAST(turn_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (typeof(configuration_json) = 'blob'),
            CHECK (length(configuration_json) BETWEEN 2 AND 65536),
            CHECK (typeof(reducer_state_json) = 'blob'),
            CHECK (length(reducer_state_json) BETWEEN 2 AND 65536)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_supervision_current_scopes (
            task_id TEXT PRIMARY KEY NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            FOREIGN KEY (task_id, generation)
              REFERENCES bridge_supervision_scopes(task_id, generation) ON DELETE RESTRICT
        ) WITHOUT ROWID;

        CREATE TABLE bridge_supervision_checkpoints (
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            checkpoint_sequence INTEGER NOT NULL CHECK (checkpoint_sequence > 0),
            checkpoint_json BLOB NOT NULL,
            checkpoint_sha256 BLOB NOT NULL CHECK (length(checkpoint_sha256) = 32),
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            PRIMARY KEY (task_id, generation, checkpoint_sequence),
            FOREIGN KEY (task_id, generation)
              REFERENCES bridge_supervision_scopes(task_id, generation) ON DELETE RESTRICT,
            CHECK (typeof(checkpoint_json) = 'blob'),
            CHECK (length(checkpoint_json) BETWEEN 2 AND 262144)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_supervision_decisions (
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            checkpoint_sequence INTEGER NOT NULL CHECK (checkpoint_sequence > 0),
            attempt INTEGER NOT NULL CHECK (attempt BETWEEN 0 AND 65535),
            result_json BLOB NOT NULL,
            result_sha256 BLOB NOT NULL CHECK (length(result_sha256) = 32),
            reducer_state_json BLOB NOT NULL,
            reducer_state_sha256 BLOB NOT NULL CHECK (length(reducer_state_sha256) = 32),
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            PRIMARY KEY (task_id, generation, checkpoint_sequence, attempt),
            FOREIGN KEY (task_id, generation, checkpoint_sequence)
              REFERENCES bridge_supervision_checkpoints(
                task_id, generation, checkpoint_sequence
              ) ON DELETE RESTRICT,
            CHECK (typeof(result_json) = 'blob'),
            CHECK (length(result_json) BETWEEN 2 AND 16384),
            CHECK (typeof(reducer_state_json) = 'blob'),
            CHECK (length(reducer_state_json) BETWEEN 2 AND 65536)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_supervision_actions (
            action_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            checkpoint_sequence INTEGER NOT NULL CHECK (checkpoint_sequence > 0),
            attempt INTEGER NOT NULL CHECK (attempt BETWEEN 0 AND 65535),
            kind TEXT NOT NULL CHECK (kind IN ('steer', 'suspend', 'interrupt')),
            instruction TEXT NOT NULL CHECK (length(CAST(instruction AS BLOB)) BETWEEN 1 AND 4096),
            instruction_sha256 BLOB NOT NULL CHECK (length(instruction_sha256) = 32),
            state TEXT NOT NULL CHECK (state IN ('pending', 'applied', 'superseded', 'ambiguous')),
            created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
            updated_at REAL NOT NULL CHECK (typeof(updated_at) IN ('integer', 'real')),
            UNIQUE (task_id, generation, checkpoint_sequence, attempt),
            FOREIGN KEY (task_id, generation, checkpoint_sequence, attempt)
              REFERENCES bridge_supervision_decisions(
                task_id, generation, checkpoint_sequence, attempt
              ) ON DELETE RESTRICT,
            CHECK (length(CAST(action_id AS BLOB)) BETWEEN 1 AND 80)
        ) WITHOUT ROWID;

        CREATE INDEX bridge_supervision_active_scopes
        ON bridge_supervision_scopes(status, updated_at, task_id, generation);
        CREATE INDEX bridge_supervision_recovery_actions
        ON bridge_supervision_actions(state, updated_at, action_id);

        CREATE TRIGGER bridge_supervision_checkpoints_no_update
        BEFORE UPDATE ON bridge_supervision_checkpoints
        BEGIN SELECT RAISE(ABORT, 'supervision checkpoints are append-only'); END;
        CREATE TRIGGER bridge_supervision_checkpoints_no_delete
        BEFORE DELETE ON bridge_supervision_checkpoints
        BEGIN SELECT RAISE(ABORT, 'supervision checkpoints are append-only'); END;
        CREATE TRIGGER bridge_supervision_decisions_no_update
        BEFORE UPDATE ON bridge_supervision_decisions
        BEGIN SELECT RAISE(ABORT, 'supervision decisions are append-only'); END;
        CREATE TRIGGER bridge_supervision_decisions_no_delete
        BEFORE DELETE ON bridge_supervision_decisions
        BEGIN SELECT RAISE(ABORT, 'supervision decisions are append-only'); END;
        """
    )
  }

  private static func validate(_ database: DatabaseQueue) throws {
    try database.read { db in
      guard
        try Int64.fetchOne(
          db,
          sql: "SELECT schema_version FROM bridge_supervision_meta WHERE singleton = 1"
        ) == version
      else { throw DurableSupervisionLedgerError.corruptSchema }
      let expected: [String: Set<String>] = [
        "bridge_supervision_meta": ["singleton", "schema_version"],
        "bridge_supervision_scopes": [
          "task_id", "generation", "project_id", "thread_id", "turn_id", "status",
          "configuration_json", "configuration_sha256", "reducer_state_json",
          "reducer_state_sha256", "created_at", "updated_at",
        ],
        "bridge_supervision_current_scopes": ["task_id", "generation"],
        "bridge_supervision_checkpoints": [
          "task_id", "generation", "checkpoint_sequence", "checkpoint_json",
          "checkpoint_sha256", "created_at",
        ],
        "bridge_supervision_decisions": [
          "task_id", "generation", "checkpoint_sequence", "attempt", "result_json",
          "result_sha256", "reducer_state_json", "reducer_state_sha256", "created_at",
        ],
        "bridge_supervision_actions": [
          "action_id", "task_id", "generation", "checkpoint_sequence", "attempt", "kind",
          "instruction", "instruction_sha256", "state", "created_at", "updated_at",
        ],
      ]
      for (table, columns) in expected {
        guard try db.tableExists(table), Set(try db.columns(in: table).map(\.name)) == columns
        else { throw DurableSupervisionLedgerError.corruptSchema }
      }
      let expectedTriggers: Set<String> = [
        "bridge_supervision_checkpoints_no_update",
        "bridge_supervision_checkpoints_no_delete",
        "bridge_supervision_decisions_no_update",
        "bridge_supervision_decisions_no_delete",
      ]
      let triggers = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'trigger' AND name GLOB 'bridge_supervision_*_no_*'
          """
      )
      guard Set(triggers) == expectedTriggers else {
        throw DurableSupervisionLedgerError.corruptSchema
      }
    }
  }
}
