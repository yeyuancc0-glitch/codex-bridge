import GRDB

enum ServiceStoreSchema {
  static let version: Int64 = 1
  static let migrationPrefix = "BridgeServiceCore."
  static let migrationV1 = "BridgeServiceCore.v1"
  static let knownMigrations: Set<String> = [migrationV1]

  static func prepare(_ database: DatabaseQueue) throws {
    do {
      try preflight(database)
      try makeMigrator().migrate(database)
      try validate(database)
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.corruptSchema
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
        let identifiers = try String.fetchAll(
          db,
          sql: "SELECT identifier FROM grdb_migrations WHERE identifier LIKE ?",
          arguments: [migrationPrefix + "%"]
        )
        if identifiers.contains(where: { !knownMigrations.contains($0) }) {
          throw ServiceStoreError.corruptSchema
        }
      }

      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name GLOB 'bridge_service_*'
          """
      )
      guard !tables.isEmpty else { return }
      guard try db.tableExists("bridge_service_meta") else {
        throw ServiceStoreError.corruptSchema
      }
      let versions = try Int64.fetchAll(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      guard versions.count == 1 else { throw ServiceStoreError.corruptSchema }
      guard versions[0] == version else {
        throw ServiceStoreError.unsupportedSchemaVersion(versions[0])
      }
    }
  }

  private static func createVersionOne(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            schema_version INTEGER NOT NULL CHECK (schema_version > 0)
        ) WITHOUT ROWID;
        INSERT INTO bridge_service_meta (singleton, schema_version) VALUES (1, 1);

        CREATE TABLE bridge_service_projects (
            project_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            canonical_path TEXT NOT NULL,
            root_device TEXT NOT NULL,
            root_inode TEXT NOT NULL,
            read_permission TEXT NOT NULL
              CHECK (read_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            write_permission TEXT NOT NULL
              CHECK (write_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            network_permission TEXT NOT NULL
              CHECK (network_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE (canonical_path),
            UNIQUE (root_device, root_inode),
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (substr(canonical_path, 1, 1) = '/'),
            CHECK (length(CAST(canonical_path AS BLOB)) BETWEEN 1 AND 16384),
            CHECK (length(root_device) BETWEEN 1 AND 20),
            CHECK (length(root_inode) BETWEEN 1 AND 20),
            CHECK (updated_at >= created_at)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_service_settings (
            setting_key TEXT PRIMARY KEY NOT NULL,
            setting_value TEXT NOT NULL,
            updated_at REAL NOT NULL,
            CHECK (length(CAST(setting_key AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(setting_value AS BLOB)) <= 65536)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_service_tasks (
            task_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('chatgpt.mcp', 'macos.app', 'legacy.import')),
            client_request_id TEXT,
            prompt TEXT NOT NULL,
            requested_thread_id TEXT,
            codex_thread_id TEXT,
            codex_turn_id TEXT,
            status TEXT NOT NULL CHECK (status IN (
              'awaiting_local_approval', 'starting', 'running',
              'waiting_for_codex_approval', 'completed', 'failed', 'interrupted', 'unknown'
            )),
            supervisor_status TEXT NOT NULL
              CHECK (supervisor_status IN ('disabled', 'starting', 'running', 'degraded', 'completed')),
            execution_model TEXT NOT NULL,
            execution_effort TEXT NOT NULL,
            supervisor_model TEXT,
            supervisor_effort TEXT,
            permission_mode TEXT NOT NULL CHECK (permission_mode IN ('read-only', 'workspace-write')),
            network_allowed INTEGER NOT NULL CHECK (network_allowed IN (0, 1)),
            current_step TEXT,
            changed_files_json BLOB NOT NULL,
            result_summary TEXT,
            supervisor_summary TEXT,
            failure_code TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY (project_id)
              REFERENCES bridge_service_projects(project_id) ON DELETE RESTRICT,
            UNIQUE (source, client_request_id),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (client_request_id IS NULL OR
              length(CAST(client_request_id AS BLOB)) BETWEEN 1 AND 512),
            CHECK (length(CAST(prompt AS BLOB)) BETWEEN 1 AND 32768),
            CHECK (requested_thread_id IS NULL OR
              length(CAST(requested_thread_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (codex_thread_id IS NULL OR
              length(CAST(codex_thread_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (codex_turn_id IS NULL OR
              length(CAST(codex_turn_id AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (length(CAST(execution_model AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(execution_effort AS BLOB)) BETWEEN 1 AND 64),
            CHECK ((supervisor_model IS NULL) = (supervisor_effort IS NULL)),
            CHECK (supervisor_model IS NULL OR
              length(CAST(supervisor_model AS BLOB)) BETWEEN 1 AND 256),
            CHECK (supervisor_effort IS NULL OR
              length(CAST(supervisor_effort AS BLOB)) BETWEEN 1 AND 64),
            CHECK (typeof(changed_files_json) = 'blob'),
            CHECK (length(changed_files_json) BETWEEN 2 AND 262144),
            CHECK (current_step IS NULL OR length(CAST(current_step AS BLOB)) <= 4096),
            CHECK (result_summary IS NULL OR length(CAST(result_summary AS BLOB)) <= 32768),
            CHECK (supervisor_summary IS NULL OR
              length(CAST(supervisor_summary AS BLOB)) <= 16384),
            CHECK (failure_code IS NULL OR
              length(CAST(failure_code AS BLOB)) BETWEEN 1 AND 128),
            CHECK (updated_at >= created_at)
        ) WITHOUT ROWID;

        CREATE UNIQUE INDEX bridge_service_one_active_write_task
        ON bridge_service_tasks(project_id)
        WHERE permission_mode = 'workspace-write'
          AND status IN (
            'awaiting_local_approval', 'starting', 'running',
            'waiting_for_codex_approval', 'unknown'
          );

        CREATE INDEX bridge_service_tasks_updated
        ON bridge_service_tasks(updated_at DESC, task_id);

        CREATE INDEX bridge_service_tasks_project_updated
        ON bridge_service_tasks(project_id, updated_at DESC, task_id);

        CREATE TABLE bridge_service_task_events (
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN (
              'task.created', 'task.approved', 'execution.starting', 'execution.started',
              'execution.plan_updated', 'execution.command_completed', 'execution.file_changed',
              'approval.requested', 'approval.resolved', 'supervisor.started',
              'supervisor.decision', 'supervisor.degraded', 'execution.turn_completed',
              'task.completed', 'task.failed', 'task.interrupted', 'task.marked_unknown'
            )),
            summary TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY (task_id)
              REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(summary AS BLOB)) BETWEEN 1 AND 8192)
        );

        CREATE INDEX bridge_service_task_events_task
        ON bridge_service_task_events(task_id, event_id DESC);
        """)
  }

  private static func validate(_ database: DatabaseQueue) throws {
    try database.read { db in
      let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
      guard quickCheck == "ok" else { throw ServiceStoreError.corruptSchema }
      guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
        throw ServiceStoreError.corruptSchema
      }
      guard
        try Int64.fetchOne(
          db,
          sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
        ) == version
      else {
        throw ServiceStoreError.corruptSchema
      }

      let requiredColumns: [String: Set<String>] = [
        "bridge_service_meta": ["singleton", "schema_version"],
        "bridge_service_projects": [
          "project_id", "name", "canonical_path", "root_device", "root_inode",
          "read_permission", "write_permission", "network_permission", "created_at", "updated_at",
        ],
        "bridge_service_settings": ["setting_key", "setting_value", "updated_at"],
        "bridge_service_tasks": [
          "task_id", "project_id", "source", "client_request_id", "prompt",
          "requested_thread_id", "codex_thread_id", "codex_turn_id", "status",
          "supervisor_status", "execution_model", "execution_effort", "supervisor_model",
          "supervisor_effort", "permission_mode", "network_allowed", "current_step",
          "changed_files_json", "result_summary", "supervisor_summary", "failure_code",
          "created_at", "updated_at",
        ],
        "bridge_service_task_events": [
          "event_id", "task_id", "kind", "summary", "created_at",
        ],
      ]
      for (table, expected) in requiredColumns {
        guard try db.tableExists(table) else { throw ServiceStoreError.corruptSchema }
        guard Set(try db.columns(in: table).map(\.name)) == expected else {
          throw ServiceStoreError.corruptSchema
        }
      }
    }
  }
}
