import Foundation
import GRDB

private struct LegacySafeRule: Decodable {
  let id: String
  let name: String
  let executable: String
  let argumentsPrefix: [String]
}

private struct LegacyWorkspaceCommand: Codable {
  let id: String
  let name: String
  let executable: String
  let arguments: [String]
  let workingDirectory: String?
  let requiresNetwork: Bool
  let risk: String
}

enum ServiceStoreSchema {
  static let version: Int64 = 9
  static let migrationPrefix = "BridgeServiceCore."
  static let migrationV1 = "BridgeServiceCore.v1"
  static let migrationV2 = "BridgeServiceCore.v2"
  static let migrationV3 = "BridgeServiceCore.v3"
  static let migrationV4 = "BridgeServiceCore.v4"
  static let migrationV5 = "BridgeServiceCore.v5"
  static let migrationV6 = "BridgeServiceCore.v6"
  static let migrationV7 = "BridgeServiceCore.v7"
  static let migrationV8 = "BridgeServiceCore.v8"
  static let migrationV9 = "BridgeServiceCore.v9"
  static let knownMigrations: Set<String> = [
    migrationV1, migrationV2, migrationV3, migrationV4, migrationV5, migrationV6, migrationV7,
    migrationV8, migrationV9,
  ]

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

  static func createPreVersionEightBackupIfNeeded(
    _ database: DatabaseQueue,
    sourcePath: String
  ) throws {
    guard sourcePath != ":memory:" else { return }
    let requiresBackup = try database.read { db -> Bool in
      guard try db.tableExists("bridge_service_meta") else { return false }
      return try Int64.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      ) == 7
    }
    guard requiresBackup else { return }
    let backupPath = sourcePath + ".pre-v8"
    if try ServiceStorePrivateBackup.prepare(at: backupPath) == .existing {
      try ServiceStorePrivateBackup.validate(at: backupPath)
      return
    }
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let destination = try DatabaseQueue(path: backupPath, configuration: configuration)
    do {
      try database.backup(to: destination)
      try ServiceStorePrivateBackup.protectAndValidate(at: backupPath)
    } catch {
      try? FileManager.default.removeItem(atPath: backupPath)
      throw error
    }
  }

  static func createPreVersionNineBackupIfNeeded(
    _ database: DatabaseQueue,
    sourcePath: String
  ) throws {
    guard sourcePath != ":memory:" else { return }
    let requiresBackup = try database.read { db -> Bool in
      guard try db.tableExists("bridge_service_meta") else { return false }
      return try Int64.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      ) == 8
    }
    guard requiresBackup else { return }
    let backupPath = sourcePath + ".pre-v9"
    if try ServiceStorePrivateBackup.prepare(at: backupPath) == .existing {
      try ServiceStorePrivateBackup.validate(at: backupPath)
      return
    }
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let destination = try DatabaseQueue(path: backupPath, configuration: configuration)
    do {
      try database.backup(to: destination)
      try ServiceStorePrivateBackup.protectAndValidate(at: backupPath)
    } catch {
      try? FileManager.default.removeItem(atPath: backupPath)
      throw error
    }
  }

  static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(migrationV1) { db in
      try createVersionOne(in: db)
    }
    migrator.registerMigration(migrationV2) { db in
      try createVersionTwo(in: db)
    }
    migrator.registerMigration(migrationV3) { db in
      try createVersionThree(in: db)
    }
    migrator.registerMigration(migrationV4) { db in
      try createVersionFour(in: db)
    }
    migrator.registerMigration(migrationV5) { db in
      try createVersionFive(in: db)
    }
    migrator.registerMigration(migrationV6) { db in
      try createVersionSix(in: db)
    }
    migrator.registerMigration(migrationV7) { db in
      try createVersionSeven(in: db)
    }
    migrator.registerMigration(migrationV8) { db in
      try createVersionEight(in: db)
    }
    migrator.registerMigration(migrationV9) { db in
      try createVersionNine(in: db)
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
      guard (1...version).contains(versions[0]) else {
        throw ServiceStoreError.unsupportedSchemaVersion(versions[0])
      }
    }
  }

  static func createVersionTwo(in db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_tasks
        ADD COLUMN access_mode TEXT NOT NULL DEFAULT 'request-approval'
          CHECK (access_mode IN ('request-approval', 'auto-review', 'full-access'));

        ALTER TABLE bridge_service_tasks
        ADD COLUMN fast_mode INTEGER NOT NULL DEFAULT 0 CHECK (fast_mode IN (0, 1));

        UPDATE bridge_service_meta SET schema_version = 2 WHERE singleton = 1;
        """)
  }

  static func createVersionThree(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_task_messages (
            message_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            message_key TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'agent')),
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY (task_id)
              REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
            UNIQUE (task_id, message_key),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(message_key AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 262144)
        );

        CREATE INDEX bridge_service_task_messages_task
        ON bridge_service_task_messages(task_id, message_id);

        UPDATE bridge_service_meta SET schema_version = 3 WHERE singleton = 1;
        """)
  }

  static func createVersionFour(in db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_task_messages
          ADD COLUMN kind TEXT NOT NULL DEFAULT 'agent'
            CHECK (kind IN ('user', 'agent', 'reasoning', 'tool_call'));

        ALTER TABLE bridge_service_task_messages
          ADD COLUMN tool_name TEXT;

        ALTER TABLE bridge_service_task_messages
          ADD COLUMN tool_status TEXT
            CHECK (tool_status IN ('inProgress', 'completed', 'failed'));

        ALTER TABLE bridge_service_task_messages
          ADD COLUMN tool_arguments TEXT;

        UPDATE bridge_service_task_messages
          SET kind = CASE WHEN role = 'user' THEN 'user' ELSE 'agent' END;

        UPDATE bridge_service_meta SET schema_version = 4 WHERE singleton = 1;
        """)
  }

  static func createVersionFive(in db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_projects
          ADD COLUMN direct_command_mode TEXT NOT NULL DEFAULT 'registered'
            CHECK (direct_command_mode IN ('denied', 'registered', 'safe'));

        ALTER TABLE bridge_service_projects
          ADD COLUMN workspace_commands_json BLOB NOT NULL DEFAULT '[]';

        UPDATE bridge_service_meta SET schema_version = 5 WHERE singleton = 1;
        """)
  }

  static func createVersionSix(in db: Database) throws {
    try db.execute(
      sql: """
        UPDATE bridge_service_projects
          SET direct_command_mode = 'safe'
          WHERE direct_command_mode = 'registered';

        ALTER TABLE bridge_service_projects RENAME TO bridge_service_projects_v5;

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
            direct_command_mode TEXT NOT NULL DEFAULT 'safe'
              CHECK (direct_command_mode IN ('denied', 'safe', 'full')),
            workspace_commands_json BLOB NOT NULL DEFAULT '[]',
            direct_safe_whitelist_json BLOB NOT NULL DEFAULT '[]',
            direct_blacklist_json BLOB NOT NULL DEFAULT '[]',
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

        INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json,
            direct_safe_whitelist_json, direct_blacklist_json,
            created_at, updated_at
        )
        SELECT
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json,
            '[]', '[]',
            created_at, updated_at
        FROM bridge_service_projects_v5;

        DROP TABLE bridge_service_projects_v5;

        UPDATE bridge_service_meta SET schema_version = 6 WHERE singleton = 1;
        """)
  }

  static func createVersionSeven(in db: Database) throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    let rows = try Row.fetchAll(
      db,
      sql:
        "SELECT project_id, workspace_commands_json, direct_safe_whitelist_json FROM bridge_service_projects"
    )
    for row in rows {
      let projectID = row["project_id"] as String
      let commandsData: Data = row["workspace_commands_json"]
      let whitelistData: Data = row["direct_safe_whitelist_json"]
      let commands = try decoder.decode([LegacyWorkspaceCommand].self, from: commandsData)
      let whitelist = try decoder.decode([LegacySafeRule].self, from: whitelistData)
      guard !whitelist.isEmpty else { continue }
      let merged =
        commands
        + whitelist.map { rule in
          LegacyWorkspaceCommand(
            id: rule.id,
            name: rule.name,
            executable: rule.executable,
            arguments: rule.argumentsPrefix,
            workingDirectory: nil,
            requiresNetwork: false,
            risk: "normal"
          )
        }
      let mergedData = try encoder.encode(merged)
      try db.execute(
        sql: "UPDATE bridge_service_projects SET workspace_commands_json = ? WHERE project_id = ?",
        arguments: [mergedData, projectID]
      )
    }
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_projects DROP COLUMN direct_safe_whitelist_json;
        UPDATE bridge_service_meta SET schema_version = 7 WHERE singleton = 1;
        """)
  }

  static func createVersionEight(in db: Database) throws {
    let taskCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_tasks") ?? 0
    let eventCount =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_task_events") ?? 0
    let messageCount =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_task_messages") ?? 0
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_tasks_v8 (
            task_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN (
              'chatgpt.mcp', 'mcp.client', 'macos.app', 'legacy.import'
            )),
            source_client_id TEXT NOT NULL DEFAULT '',
            client_request_id TEXT,
            prompt TEXT NOT NULL,
            requested_thread_id TEXT,
            codex_thread_id TEXT,
            codex_turn_id TEXT,
            status TEXT NOT NULL CHECK (status IN (
              'awaiting_local_approval', 'starting', 'running',
              'waiting_for_codex_approval', 'completed', 'failed', 'interrupted', 'unknown'
            )),
            supervisor_status TEXT NOT NULL CHECK (supervisor_status IN (
              'disabled', 'starting', 'running', 'degraded', 'completed'
            )),
            execution_model TEXT NOT NULL,
            execution_effort TEXT NOT NULL,
            supervisor_model TEXT,
            supervisor_effort TEXT,
            permission_mode TEXT NOT NULL
              CHECK (permission_mode IN ('read-only', 'workspace-write')),
            network_allowed INTEGER NOT NULL CHECK (network_allowed IN (0, 1)),
            access_mode TEXT NOT NULL DEFAULT 'request-approval'
              CHECK (access_mode IN ('request-approval', 'auto-review', 'full-access')),
            fast_mode INTEGER NOT NULL DEFAULT 0 CHECK (fast_mode IN (0, 1)),
            current_step TEXT,
            changed_files_json BLOB NOT NULL,
            result_summary TEXT,
            supervisor_summary TEXT,
            failure_code TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY (project_id)
              REFERENCES bridge_service_projects(project_id) ON DELETE RESTRICT,
            UNIQUE (source, source_client_id, client_request_id),
            CHECK (
              (source = 'mcp.client'
                AND length(CAST(source_client_id AS BLOB)) BETWEEN 1 AND 128)
              OR (source <> 'mcp.client' AND source_client_id = '')
            ),
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

        INSERT INTO bridge_service_tasks_v8 (
            task_id, project_id, source, source_client_id, client_request_id, prompt,
            requested_thread_id, codex_thread_id, codex_turn_id, status,
            supervisor_status, execution_model, execution_effort, supervisor_model,
            supervisor_effort, permission_mode, network_allowed, access_mode, fast_mode,
            current_step, changed_files_json, result_summary, supervisor_summary,
            failure_code, created_at, updated_at
        )
        SELECT
            task_id, project_id, source, '', client_request_id, prompt,
            requested_thread_id, codex_thread_id, codex_turn_id, status,
            supervisor_status, execution_model, execution_effort, supervisor_model,
            supervisor_effort, permission_mode, network_allowed, access_mode, fast_mode,
            current_step, changed_files_json, result_summary, supervisor_summary,
            failure_code, created_at, updated_at
        FROM bridge_service_tasks;

        CREATE TABLE bridge_service_task_events_v8_staging (
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
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(summary AS BLOB)) BETWEEN 1 AND 8192)
        );

        INSERT INTO bridge_service_task_events_v8_staging
          (event_id, task_id, kind, summary, created_at)
        SELECT event_id, task_id, kind, summary, created_at
        FROM bridge_service_task_events;

        CREATE TABLE bridge_service_task_messages_v8_staging (
            message_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            message_key TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'agent')),
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL DEFAULT 'agent'
              CHECK (kind IN ('user', 'agent', 'reasoning', 'tool_call')),
            tool_name TEXT,
            tool_status TEXT CHECK (tool_status IN ('inProgress', 'completed', 'failed')),
            tool_arguments TEXT,
            UNIQUE (task_id, message_key),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(message_key AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 262144)
        );

        INSERT INTO bridge_service_task_messages_v8_staging (
          message_id, task_id, message_key, role, content, created_at, kind,
          tool_name, tool_status, tool_arguments
        )
        SELECT
          message_id, task_id, message_key, role, content, created_at, kind,
          tool_name, tool_status, tool_arguments
        FROM bridge_service_task_messages;

        DROP TABLE bridge_service_task_messages;
        DROP TABLE bridge_service_task_events;
        DROP TABLE bridge_service_tasks;

        ALTER TABLE bridge_service_tasks_v8 RENAME TO bridge_service_tasks;

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

        INSERT INTO bridge_service_task_events
          (event_id, task_id, kind, summary, created_at)
        SELECT event_id, task_id, kind, summary, created_at
        FROM bridge_service_task_events_v8_staging;
        DROP TABLE bridge_service_task_events_v8_staging;

        CREATE TABLE bridge_service_task_messages (
            message_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            message_key TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'agent')),
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL DEFAULT 'agent'
              CHECK (kind IN ('user', 'agent', 'reasoning', 'tool_call')),
            tool_name TEXT,
            tool_status TEXT CHECK (tool_status IN ('inProgress', 'completed', 'failed')),
            tool_arguments TEXT,
            FOREIGN KEY (task_id)
              REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
            UNIQUE (task_id, message_key),
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(message_key AS BLOB)) BETWEEN 1 AND 256),
            CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 262144)
        );

        INSERT INTO bridge_service_task_messages (
          message_id, task_id, message_key, role, content, created_at, kind,
          tool_name, tool_status, tool_arguments
        )
        SELECT
          message_id, task_id, message_key, role, content, created_at, kind,
          tool_name, tool_status, tool_arguments
        FROM bridge_service_task_messages_v8_staging;
        DROP TABLE bridge_service_task_messages_v8_staging;

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
        CREATE INDEX bridge_service_task_events_task
        ON bridge_service_task_events(task_id, event_id DESC);
        CREATE INDEX bridge_service_task_messages_task
        ON bridge_service_task_messages(task_id, message_id);

        UPDATE bridge_service_meta SET schema_version = 8 WHERE singleton = 1;
        """)
    guard
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_tasks") == taskCount,
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_task_events") == eventCount,
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_task_messages")
        == messageCount,
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
    else {
      throw ServiceStoreError.corruptSchema
    }
  }

  static func createVersionNine(in db: Database) throws {
    let projectCount =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_projects") ?? 0
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_projects RENAME TO bridge_service_projects_v8;

        CREATE TABLE bridge_service_projects (
            project_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            canonical_path TEXT NOT NULL,
            root_identity_kind TEXT NOT NULL,
            root_identity_volume TEXT NOT NULL,
            root_identity_file TEXT NOT NULL,
            read_permission TEXT NOT NULL
              CHECK (read_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            write_permission TEXT NOT NULL
              CHECK (write_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            network_permission TEXT NOT NULL
              CHECK (network_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
            direct_command_mode TEXT NOT NULL DEFAULT 'safe'
              CHECK (direct_command_mode IN ('denied', 'safe', 'full')),
            workspace_commands_json BLOB NOT NULL DEFAULT '[]',
            direct_blacklist_json BLOB NOT NULL DEFAULT '[]',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE (canonical_path),
            UNIQUE (root_identity_kind, root_identity_volume, root_identity_file),
            CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 128),
            CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 1024),
            CHECK (length(CAST(canonical_path AS BLOB)) BETWEEN 1 AND 16384),
            CHECK (root_identity_kind IN ('posix-v1', 'windows-fileid128-v1')),
            CHECK (length(root_identity_volume) BETWEEN 1 AND 20
              AND root_identity_volume NOT GLOB '*[^0-9]*'),
            CHECK (
              (root_identity_kind = 'posix-v1'
                AND length(root_identity_file) BETWEEN 1 AND 20
                AND root_identity_file NOT GLOB '*[^0-9]*')
              OR (root_identity_kind = 'windows-fileid128-v1'
                AND length(root_identity_file) = 32
                AND root_identity_file NOT GLOB '*[^0-9a-f]*')
            ),
            CHECK (updated_at >= created_at)
        ) WITHOUT ROWID;

        INSERT INTO bridge_service_projects (
            project_id, name, canonical_path,
            root_identity_kind, root_identity_volume, root_identity_file,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
        )
        SELECT
            project_id, name, canonical_path,
            'posix-v1', root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
        FROM bridge_service_projects_v8;

        DROP TABLE bridge_service_projects_v8;

        UPDATE bridge_service_meta SET schema_version = 9 WHERE singleton = 1;
        """)
    guard
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_service_projects") == projectCount,
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
    else {
      throw ServiceStoreError.corruptSchema
    }
  }

  static func createVersionOne(in db: Database) throws {
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
          "project_id", "name", "canonical_path",
          "root_identity_kind", "root_identity_volume", "root_identity_file",
          "read_permission", "write_permission", "network_permission", "created_at", "updated_at",
          "direct_command_mode", "workspace_commands_json",
          "direct_blacklist_json",
        ],
        "bridge_service_settings": ["setting_key", "setting_value", "updated_at"],
        "bridge_service_tasks": [
          "task_id", "project_id", "source", "source_client_id", "client_request_id", "prompt",
          "requested_thread_id", "codex_thread_id", "codex_turn_id", "status",
          "supervisor_status", "execution_model", "execution_effort", "supervisor_model",
          "supervisor_effort", "permission_mode", "network_allowed", "access_mode",
          "fast_mode", "current_step",
          "changed_files_json", "result_summary", "supervisor_summary", "failure_code",
          "created_at", "updated_at",
        ],
        "bridge_service_task_events": [
          "event_id", "task_id", "kind", "summary", "created_at",
        ],
        "bridge_service_task_messages": [
          "message_id", "task_id", "message_key", "role", "kind", "content",
          "tool_name", "tool_status", "tool_arguments", "created_at",
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
