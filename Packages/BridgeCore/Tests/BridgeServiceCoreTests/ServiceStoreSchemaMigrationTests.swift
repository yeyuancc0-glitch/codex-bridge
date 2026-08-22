import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Darwin
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceStoreSchemaMigrationTests: XCTestCase {
  func testVersionOneDatabaseMigratesToAccessModeAndFastModeColumns() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier) VALUES ('BridgeServiceCore.v1');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission, created_at, updated_at
          ) VALUES ('prj-legacy', 'Legacy', '/tmp/legacy', '1', '2',
            'allowed', 'allowed', 'denied', 1, 2)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, client_request_id, prompt, requested_thread_id,
            codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
            execution_effort, supervisor_model, supervisor_effort, permission_mode,
            network_allowed, current_step, changed_files_json, result_summary,
            supervisor_summary, failure_code, created_at, updated_at
          ) VALUES ('tsk-legacy', 'prj-legacy', 'chatgpt.mcp', NULL, 'Legacy prompt', NULL,
            NULL, NULL, 'completed', 'disabled', 'legacy-model', 'medium', NULL, NULL,
            'workspace-write', 0, NULL, CAST('[]' AS BLOB), NULL, NULL, NULL, 1, 2)
          """
      )
    }

    let store = try SimpleServiceStore(path: path)
    let task = try await store.task(id: TaskID(rawValue: "tsk-legacy"))
    XCTAssertEqual(task?.accessMode, .requestApproval)
    XCTAssertEqual(task?.fastMode, false)
    XCTAssertEqual(task?.state.status, .completed)

    let project = try await store.project(id: ProjectID(rawValue: "prj-legacy"))
    XCTAssertNotNil(project)

    let tasks = ServiceTaskManager(store: store)
    let created = try await tasks.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: "prj-legacy"),
        source: .macOSApp,
        prompt: "New task after migration.",
        executionModel: "new-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite,
        accessMode: .fullAccess,
        fastMode: true
      )
    )
    XCTAssertEqual(created.task.accessMode, .fullAccess)
    XCTAssertTrue(created.task.fastMode)

    let reopened = try SimpleServiceStore(path: path)
    let reloaded = try await reopened.task(id: created.task.id)
    XCTAssertEqual(reloaded?.accessMode, .fullAccess)
    XCTAssertEqual(reloaded?.fastMode, true)
  }

  func testVersionTwoDatabaseMigratesToTaskMessagesTable() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v3-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission, created_at, updated_at
          ) VALUES ('prj-v2', 'Legacy', '/tmp/legacy', '1', '2',
            'allowed', 'allowed', 'denied', 1, 2)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, client_request_id, prompt, requested_thread_id,
            codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
            execution_effort, supervisor_model, supervisor_effort, permission_mode,
            network_allowed, current_step, changed_files_json, result_summary,
            supervisor_summary, failure_code, access_mode, fast_mode, created_at, updated_at
          ) VALUES ('tsk-v2', 'prj-v2', 'chatgpt.mcp', NULL, 'Legacy prompt', NULL,
            NULL, NULL, 'completed', 'disabled', 'legacy-model', 'medium', NULL, NULL,
            'workspace-write', 0, NULL, CAST('[]' AS BLOB), NULL, NULL, NULL,
            'request-approval', 0, 1, 2)
          """
      )
    }

    let store = try SimpleServiceStore(path: path)
    let stored = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "user:1",
        role: .user,
        content: "Migrated conversation.",
        createdAt: Date(timeIntervalSince1970: 1_800_000_200)
      ),
      taskID: TaskID(rawValue: "tsk-v2")
    )
    XCTAssertEqual(stored.role, .user)

    let reopened = try SimpleServiceStore(path: path)
    let messages = try await reopened.taskMessages(taskID: TaskID(rawValue: "tsk-v2"))
    XCTAssertEqual(messages.map(\.key), ["user:1"])
    XCTAssertEqual(messages[0].content, "Migrated conversation.")
  }

  func testVersionThreeDatabaseMigratesToMessageKindAndToolColumns() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v4-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'), ('BridgeServiceCore.v3');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission, created_at, updated_at
          ) VALUES ('prj-v3', 'Legacy', '/tmp/legacy', '1', '2',
            'allowed', 'allowed', 'denied', 1, 2)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, client_request_id, prompt, requested_thread_id,
            codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
            execution_effort, supervisor_model, supervisor_effort, permission_mode,
            network_allowed, current_step, changed_files_json, result_summary,
            supervisor_summary, failure_code, access_mode, fast_mode, created_at, updated_at
          ) VALUES ('tsk-v3', 'prj-v3', 'chatgpt.mcp', NULL, 'Legacy prompt', NULL,
            NULL, NULL, 'completed', 'disabled', 'legacy-model', 'medium', NULL, NULL,
            'workspace-write', 0, NULL, CAST('[]' AS BLOB), NULL, NULL, NULL,
            'request-approval', 0, 1, 2)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_task_messages (
            task_id, message_key, role, content, created_at
          ) VALUES
            ('tsk-v3', 'user:1', 'user', 'Legacy user prompt.', 3),
            ('tsk-v3', 'agent:1', 'agent', 'Legacy agent reply.', 4)
          """
      )
    }

    let store = try SimpleServiceStore(path: path)
    let messages = try await store.taskMessages(taskID: TaskID(rawValue: "tsk-v3"))
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].kind, .user)
    XCTAssertEqual(messages[1].kind, .agent)

    let stored = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "reasoning:1",
        role: .agent,
        content: "Let me think about this.",
        createdAt: Date(timeIntervalSince1970: 1_800_000_300),
        kind: .reasoning
      ),
      taskID: TaskID(rawValue: "tsk-v3")
    )
    XCTAssertEqual(stored.kind, .reasoning)

    let tool = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "tool:1",
        role: .agent,
        content: #"{"path":"Sources/A.swift"}"#,
        createdAt: Date(timeIntervalSince1970: 1_800_000_400),
        kind: .toolCall,
        toolName: "read",
        toolStatus: "completed",
        toolArguments: #"{"path":"Sources/A.swift"}"#
      ),
      taskID: TaskID(rawValue: "tsk-v3")
    )
    XCTAssertEqual(tool.kind, .toolCall)
    XCTAssertEqual(tool.toolName, "read")
    XCTAssertEqual(tool.toolStatus, "completed")

    let reopened = try SimpleServiceStore(path: path)
    let reloaded = try await reopened.taskMessages(taskID: TaskID(rawValue: "tsk-v3"))
    let reloadedTool = reloaded.first { $0.key == "tool:1" }
    XCTAssertEqual(reloadedTool?.kind, .toolCall)
    XCTAssertEqual(reloadedTool?.toolName, "read")
    XCTAssertEqual(reloadedTool?.toolStatus, "completed")
    XCTAssertEqual(reloadedTool?.toolArguments, #"{"path":"Sources/A.swift"}"#)
  }

  func testVersionFourDatabaseMigratesToWorkspaceCommandColumns() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v5-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission, created_at, updated_at
          ) VALUES ('prj-v4', 'Legacy', '/tmp/legacy', '1', '2',
            'allowed', 'requiresLocalApproval', 'denied', 1, 2)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, client_request_id, prompt, requested_thread_id,
            codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
            execution_effort, supervisor_model, supervisor_effort, permission_mode,
            network_allowed, current_step, changed_files_json, result_summary,
            supervisor_summary, failure_code, access_mode, fast_mode, created_at, updated_at
          ) VALUES ('tsk-v4', 'prj-v4', 'chatgpt.mcp', NULL, 'Legacy prompt', NULL,
            NULL, NULL, 'completed', 'disabled', 'legacy-model', 'medium', NULL, NULL,
            'workspace-write', 0, NULL, CAST('[]' AS BLOB), NULL, NULL, NULL,
            'request-approval', 0, 1, 2)
          """
      )
    }

    let store = try SimpleServiceStore(path: path)
    let project = try await store.project(id: ProjectID(rawValue: "prj-v4"))
    XCTAssertEqual(project?.directCommandMode, .safe)
    XCTAssertTrue(project?.workspaceCommands.isEmpty ?? false)
    XCTAssertEqual(project?.accessPolicy.write, .requiresLocalApproval)

    try await store.updateWorkspaceConfiguration(
      projectID: ProjectID(rawValue: "prj-v4"),
      directCommandMode: .safe,
      workspaceCommands: [
        try ServiceWorkspaceCommand(
          id: "wcmd-test",
          name: "Tests",
          executable: "Scripts/with-xcode.sh",
          arguments: ["swift", "test"]
        )
      ],
      commandBlacklist: [],
      at: Date(timeIntervalSince1970: 3)
    )
    let updated = try await store.project(id: ProjectID(rawValue: "prj-v4"))
    XCTAssertEqual(updated?.directCommandMode, .safe)
    XCTAssertEqual(updated?.workspaceCommands.count, 1)
    XCTAssertEqual(updated?.workspaceCommands[0].name, "Tests")
    XCTAssertEqual(updated?.accessPolicy.write, .requiresLocalApproval)
    XCTAssertEqual(updated?.accessPolicy.read, .allowed)

    let reopened = try SimpleServiceStore(path: path)
    let reloaded = try await reopened.project(id: ProjectID(rawValue: "prj-v4"))
    XCTAssertEqual(reloaded?.directCommandMode, .safe)
    XCTAssertEqual(reloaded?.workspaceCommands.map(\.id), ["wcmd-test"])

    let task = try await reopened.task(id: TaskID(rawValue: "tsk-v4"))
    XCTAssertEqual(task?.state.status, .completed)
  }

  func testVersionSixWhitelistColumnMergesIntoWorkspaceCommandsAndIsDropped() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v7-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
                 ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      let commandsJSON = """
        [{"id":"wcmd-build","name":"Build","executable":"swift","arguments":["build"],
        "workingDirectory":null,"requiresNetwork":false,"risk":"normal"}]
        """
      let whitelistJSON = """
        [{"id":"safe-node","name":"Node","executable":"node",
        "argumentsPrefix":["scripts/tool.js"]}]
        """
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json,
            direct_safe_whitelist_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-v6', 'V6', '/tmp/v6', '1', '2',
            'allowed', 'requiresLocalApproval', 'denied',
            'safe', CAST(? AS BLOB), CAST(? AS BLOB), CAST('[]' AS BLOB), 1, 2)
          """,
        arguments: [commandsJSON, whitelistJSON]
      )
    }

    let store = try SimpleServiceStore(path: path)
    let project = try await store.project(id: ProjectID(rawValue: "prj-v6"))
    let commands = try XCTUnwrap(project?.workspaceCommands)
    XCTAssertEqual(commands.count, 2)
    XCTAssertEqual(commands.map(\.id), ["wcmd-build", "safe-node"])
    XCTAssertEqual(commands[1].name, "Node")
    XCTAssertEqual(commands[1].executable, "node")
    XCTAssertEqual(commands[1].arguments, ["scripts/tool.js"])
    XCTAssertEqual(commands[1].risk, .normal)

    // Column must be dropped so reopening stays valid and v7 is recorded.
    let reopened = try SimpleServiceStore(path: path)
    let reloaded = try await reopened.project(id: ProjectID(rawValue: "prj-v6"))
    XCTAssertEqual(reloaded?.workspaceCommands.count, 2)
    try await reopened.setSetting(
      ServiceSettingRecord(key: "probe", value: "ok", updatedAt: Date(timeIntervalSince1970: 4)))
    let probe = try await reopened.setting(key: "probe")
    XCTAssertEqual(probe?.value, "ok")
  }

  func testVersionSevenRejectsCorruptLegacyJSONAndRollsBackMigration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v7-corrupt-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
                 ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json,
            direct_safe_whitelist_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-corrupt', 'Corrupt', '/tmp/corrupt', '1', '2',
            'allowed', 'allowed', 'denied', 'safe', CAST(? AS BLOB),
            CAST('[]' AS BLOB), CAST('[]' AS BLOB), 1, 2)
          """,
        arguments: ["{not-json"]
      )
    }

    XCTAssertThrowsError(try SimpleServiceStore(path: path))

    let rolledBack = try DatabaseQueue(path: path)
    let version = try rolledBack.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(version, 6)
    let hasLegacyColumn = try rolledBack.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(bridge_service_projects)")
        .contains { ($0["name"] as String?) == "direct_safe_whitelist_json" }
    }
    XCTAssertTrue(hasLegacyColumn)
    let preservedJSON = try rolledBack.read { db in
      try String.fetchOne(
        db,
        sql:
          "SELECT CAST(workspace_commands_json AS TEXT) FROM bridge_service_projects WHERE project_id = ?",
        arguments: ["prj-corrupt"]
      )
    }
    XCTAssertEqual(preservedJSON, "{not-json")
    let migrations = try rolledBack.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    XCTAssertEqual(
      migrations,
      [
        "BridgeServiceCore.v1", "BridgeServiceCore.v2", "BridgeServiceCore.v3",
        "BridgeServiceCore.v4", "BridgeServiceCore.v5", "BridgeServiceCore.v6",
      ])
  }

  func testVersionSevenMigratesTasksEventsMessagesAndCreatesPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v8-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path
    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
                 ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6'),
                 ('BridgeServiceCore.v7');
          """)
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      try ServiceStoreSchema.createVersionSeven(in: db)
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-v7', 'V7', '/tmp/v7', '1', '2',
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 1, 2);

          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, client_request_id, prompt, requested_thread_id,
            codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
            execution_effort, supervisor_model, supervisor_effort, permission_mode,
            network_allowed, access_mode, fast_mode, current_step, changed_files_json,
            result_summary, supervisor_summary, failure_code, created_at, updated_at
          ) VALUES ('tsk-v7', 'prj-v7', 'chatgpt.mcp', 'legacy-request', 'Legacy', NULL,
            'thread-v7', 'turn-v7', 'completed', 'disabled', 'legacy-model', 'medium',
            NULL, NULL, 'read-only', 0, 'request-approval', 0, NULL,
            CAST('[]' AS BLOB), 'Done', NULL, NULL, 3, 4);

          INSERT INTO bridge_service_task_events (task_id, kind, summary, created_at)
          VALUES ('tsk-v7', 'task.created', 'Created', 3);
          INSERT INTO bridge_service_task_messages (
            task_id, message_key, role, content, created_at, kind
          ) VALUES ('tsk-v7', 'agent:1', 'agent', 'Completed', 4, 'agent');
          """)
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    let store = try SimpleServiceStore(path: path)
    let task = try await store.task(id: TaskID(rawValue: "tsk-v7"))
    XCTAssertEqual(task?.source, .chatGPT)
    XCTAssertEqual(task?.sourceClientID, "")
    let events = try await store.events(taskID: TaskID(rawValue: "tsk-v7"))
    let messages = try await store.taskMessages(taskID: TaskID(rawValue: "tsk-v7"))
    XCTAssertEqual(events.map(\.summary), ["Created"])
    XCTAssertEqual(messages.map(\.content), ["Completed"])

    let backupPath = path + ".pre-v8"
    var metadata = stat()
    XCTAssertEqual(lstat(backupPath, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let backup = try DatabaseQueue(path: backupPath)
    let backupVersion = try await backup.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(backupVersion, 7)
  }

  func testVersionEightIdempotencyIsScopedByMCPClient() async throws {
    let store = try SimpleServiceStore.inMemory()
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-v8-idempotency-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let project = try makeServiceProject(
      id: "prj-client-idempotency",
      rootURL: root
    )
    try await store.insertProject(project)
    let foreignKeyTargets = try await store.database.read { db in
      let taskTargets = try String.fetchAll(
        db,
        sql: "SELECT \"table\" FROM pragma_foreign_key_list('bridge_service_tasks')"
      )
      let eventTargets = try String.fetchAll(
        db,
        sql: "SELECT \"table\" FROM pragma_foreign_key_list('bridge_service_task_events')"
      )
      let messageTargets = try String.fetchAll(
        db,
        sql: "SELECT \"table\" FROM pragma_foreign_key_list('bridge_service_task_messages')"
      )
      return taskTargets + eventTargets + messageTargets
    }
    XCTAssertEqual(
      foreignKeyTargets,
      ["bridge_service_projects", "bridge_service_tasks", "bridge_service_tasks"]
    )
    let manager = ServiceTaskManager(store: store)
    let base: (String) -> ServiceTaskRequest = { clientID in
      ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: clientID,
        clientRequestID: "same-request",
        prompt: "Run the same request ID from a distinct client.",
        executionModel: "fixture",
        executionEffort: "medium",
        permissionMode: .readOnly
      )
    }

    let chat = try await manager.submit(base("openai.chatgpt"))
    let qwen = try await manager.submit(base("qwen.studio"))
    let qwenReplay = try await manager.submit(base("qwen.studio"))
    XCTAssertNotEqual(chat.task.id, qwen.task.id)
    XCTAssertEqual(qwenReplay.task.id, qwen.task.id)
    XCTAssertTrue(qwenReplay.reusedExistingTask)
  }

  func testVersionEightDatabaseMigratesToGenericRootIdentityAndCreatesPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v9-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
                 ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6'),
                 ('BridgeServiceCore.v7'), ('BridgeServiceCore.v8');
          """)
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      try ServiceStoreSchema.createVersionSeven(in: db)
      try ServiceStoreSchema.createVersionEight(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-v8', 'V8', '/tmp/v8', '16777229', '678',
            'allowed', 'requiresLocalApproval', 'denied', 'safe',
            CAST('[]' AS BLOB), CAST('[]' AS BLOB), 1, 2);

          INSERT INTO bridge_service_tasks (
            task_id, project_id, source, source_client_id, client_request_id, prompt,
            requested_thread_id, codex_thread_id, codex_turn_id, status,
            supervisor_status, execution_model, execution_effort, supervisor_model,
            supervisor_effort, permission_mode, network_allowed, access_mode, fast_mode,
            current_step, changed_files_json, result_summary, supervisor_summary,
            failure_code, created_at, updated_at
          ) VALUES ('tsk-v8', 'prj-v8', 'chatgpt.mcp', '', NULL, 'Legacy prompt', NULL,
            'thread-v8', NULL, 'completed', 'disabled', 'legacy-model', 'medium', NULL, NULL,
            'read-only', 0, 'request-approval', 0, NULL,
            CAST('[]' AS BLOB), 'Done', NULL, NULL, 3, 4);
          """)
    }

    let store = try SimpleServiceStore(path: path)

    let project = try await store.project(id: ProjectID(rawValue: "prj-v8"))
    XCTAssertEqual(project?.name, "V8")
    XCTAssertEqual(project?.root.canonicalPath, "/tmp/v8")
    XCTAssertEqual(project?.root.identity.kind, FileSystemIdentity.posixKind)
    XCTAssertEqual(project?.root.identity.volumeID, "16777229")
    XCTAssertEqual(project?.root.identity.fileID, "678")
    XCTAssertEqual(project?.accessPolicy.read, .allowed)
    XCTAssertEqual(project?.accessPolicy.write, .requiresLocalApproval)
    XCTAssertEqual(project?.directCommandMode, .safe)
    XCTAssertEqual(project?.createdAt, Date(timeIntervalSince1970: 1))

    let task = try await store.task(id: TaskID(rawValue: "tsk-v8"))
    XCTAssertEqual(task?.state.status, .completed)
    XCTAssertEqual(task?.state.resultSummary, "Done")

    let backupPath = path + ".pre-v9"
    var metadata = stat()
    XCTAssertEqual(lstat(backupPath, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let backup = try DatabaseQueue(path: backupPath)
    let backupVersion = try await backup.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(backupVersion, 8)

    // Reopening the migrated database must not require re-registering projects.
    let reopened = try SimpleServiceStore(path: path)
    let reloaded = try await reopened.project(id: ProjectID(rawValue: "prj-v8"))
    XCTAssertEqual(reloaded?.root, project?.root)
    XCTAssertEqual(reloaded?.accessPolicy.read, project?.accessPolicy.read)
  }

  func testGenericRootIdentityAcceptsWindowsFileIDAndRejectsInvalidEncodings() async throws {
    let store = try SimpleServiceStore.inMemory()
    let windowsIdentity = try FileSystemIdentity(
      kind: FileSystemIdentity.windowsFileID128Kind,
      volumeID: "16777229",
      fileID: String(repeating: "0a1b2c3d", count: 4)
    )
    let windowsRoot = try ServiceRootIdentity(
      canonicalPath: "C:\\Projects\\demo",
      identity: windowsIdentity
    )
    let project = try ServiceProjectRecord(
      id: ProjectID(rawValue: "prj-win"),
      name: "Windows",
      root: windowsRoot,
      accessPolicy: ProjectAccessPolicy(),
      createdAt: Date(timeIntervalSince1970: 5),
      updatedAt: Date(timeIntervalSince1970: 5)
    )
    try await store.insertProject(project)
    let loaded = try await store.project(id: ProjectID(rawValue: "prj-win"))
    XCTAssertEqual(loaded?.root.identity, windowsIdentity)

    let sameIdentityDifferentPath = try ServiceProjectRecord(
      id: ProjectID(rawValue: "prj-win-clone"),
      name: "Clone",
      root: ServiceRootIdentity(
        canonicalPath: "C:\\Projects\\other",
        identity: windowsIdentity
      ),
      accessPolicy: ProjectAccessPolicy(),
      createdAt: Date(timeIntervalSince1970: 5),
      updatedAt: Date(timeIntervalSince1970: 5)
    )
    do {
      try await store.insertProject(sameIdentityDifferentPath)
      XCTFail("Duplicate root identity must be rejected.")
    } catch let error as ServiceStoreError {
      guard case .duplicateProjectRoot = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    for invalid in [
      ["kind": FileSystemIdentity.windowsFileID128Kind, "volume": "16777229", "file": "A1B2"],
      [
        "kind": FileSystemIdentity.windowsFileID128Kind, "volume": "16777229",
        "file": String(repeating: "a", count: 31),
      ],
      ["kind": "unknown-kind", "volume": "1", "file": "2"],
      ["kind": FileSystemIdentity.posixKind, "volume": "16_7", "file": "2"],
      [String: String](),
    ] {
      XCTAssertThrowsError(
        try FileSystemIdentity(
          kind: invalid["kind"] ?? "",
          volumeID: invalid["volume"] ?? "",
          fileID: invalid["file"] ?? ""
        ),
        "Invalid identity \(invalid) must be rejected."
      )
    }

    // The schema itself must enforce the same encodings against raw writes.
    try await store.database.write { db in
      XCTAssertThrowsError(
        try db.execute(
          sql: """
            INSERT INTO bridge_service_projects (
              project_id, name, canonical_path,
              root_identity_kind, root_identity_volume, root_identity_file,
              read_permission, write_permission, network_permission,
              created_at, updated_at
            ) VALUES ('prj-raw-bad', 'Bad', 'C:\\Bad', 'windows-fileid128-v1', '1', 'ZZ',
              'denied', 'denied', 'denied', 1, 1)
            """
        )
      )
    }
  }
}
