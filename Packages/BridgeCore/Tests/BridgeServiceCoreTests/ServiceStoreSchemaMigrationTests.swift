import BridgeDomain
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
}
