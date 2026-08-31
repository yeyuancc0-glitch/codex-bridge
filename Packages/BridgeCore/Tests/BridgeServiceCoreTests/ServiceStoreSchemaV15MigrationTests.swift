import Foundation
import GRDB
import XCTest

@testable import BridgeServiceCore

#if canImport(Darwin)
  import Darwin
#endif

final class ServiceStoreSchemaV15MigrationTests: XCTestCase {
  func testVersionFourteenDatabaseMigratesPathsAndPreservesRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v15-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    try await makeVersionFourteenDatabase(at: path)
    let store = try SimpleServiceStore(path: path)

    let migrated = try await store.database.read { db in
      let version = try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      let rows = try [
        "bridge_service_projects",
        "bridge_service_tasks",
        "bridge_service_task_events",
        "bridge_service_task_messages",
        "bridge_service_agent_installations",
        "bridge_service_agent_installation_artifacts",
      ].map { table in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
      }
      let projectSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_projects'"
      )
      let installationSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_agent_installations'"
      )
      let artifactSQL = try String.fetchOne(
        db,
        sql:
          "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_agent_installation_artifacts'"
      )
      let message = try String.fetchOne(
        db,
        sql: "SELECT content FROM bridge_service_task_messages WHERE task_id = 'tsk-v14'"
      )
      let artifactPath = try String.fetchOne(
        db,
        sql: "SELECT canonical_path FROM bridge_service_agent_installation_artifacts"
      )
      return (version, rows, projectSQL, installationSQL, artifactSQL, message, artifactPath)
    }

    XCTAssertEqual(migrated.0, 15)
    XCTAssertEqual(migrated.1, [1, 1, 1, 1, 1, 1])
    XCTAssertTrue(migrated.2?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertTrue(migrated.3?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertTrue(migrated.4?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertEqual(migrated.5, "Preserved message")
    XCTAssertEqual(migrated.6, "/tmp/v14-config")

    let indexes = try await store.database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'index' AND sql IS NOT NULL
          ORDER BY name
          """
      )
    }
    XCTAssertEqual(
      Set(indexes),
      Set([
        "bridge_service_agent_installations_provider",
        "bridge_service_agent_installations_updated",
        "bridge_service_agent_installation_artifacts_path",
        "bridge_service_agent_installation_artifacts_updated",
        "bridge_service_one_active_write_task",
        "bridge_service_task_events_task",
        "bridge_service_task_messages_activity",
        "bridge_service_task_messages_task",
        "bridge_service_tasks_project_updated",
        "bridge_service_tasks_updated",
      ])
    )
    let foreignKeyCounts = try await store.database.read { db in
      try [
        "bridge_service_projects",
        "bridge_service_tasks",
        "bridge_service_task_events",
        "bridge_service_task_messages",
        "bridge_service_agent_installations",
        "bridge_service_agent_installation_artifacts",
      ].map { table in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").count
      }
    }
    XCTAssertEqual(foreignKeyCounts, [0, 1, 1, 1, 0, 1])

    try await store.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-windows', 'Windows', ?, '3', '4',
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 3, 4)
          """,
        arguments: [#"C:\Work\Project"#]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-unc', 'UNC', ?, '7', '8',
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 5, 6)
          """,
        arguments: [#"\\Server\Share\Project"#]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_agent_installations (
            installation_id, provider_id, display_name, executable_path,
            canonical_executable_path, executable_device, executable_inode,
            executable_size, executable_mtime_ns, executable_sha256, version,
            protocol_revision, adapter_revision, trust_profile, security_profile_id,
            is_enabled, availability, capabilities_json, last_probe_error,
            last_probed_at, created_at, updated_at
          ) VALUES ('ainst-windows', 'open_code', 'Windows', ?, ?, '3', '4',
            '5', 6, ?, '1', '1', 1, 'managed', NULL, 1, 'unavailable',
            CAST('{}' AS BLOB), NULL, NULL, 3, 4)
          """,
        arguments: [
          #"C:\Tools\opencode.exe"#, #"C:\Tools\opencode.exe"#,
          String(repeating: "0", count: 64),
        ]
      )
    }

    let nativePaths = try await store.database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT canonical_path FROM bridge_service_projects ORDER BY project_id"
      )
    }
    XCTAssertEqual(
      Set(nativePaths),
      Set(["/tmp/v14", #"C:\Work\Project"#, #"\\Server\Share\Project"#])
    )

    var rejectedRelativePath = false
    do {
      try await store.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO bridge_service_projects (
              project_id, name, canonical_path, root_device, root_inode,
              read_permission, write_permission, network_permission,
              direct_command_mode, workspace_commands_json, direct_blacklist_json,
              created_at, updated_at
            ) VALUES ('prj-relative', 'Relative', 'relative/project', '9', '10',
              'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
              CAST('[]' AS BLOB), 7, 8)
            """
        )
      }
    } catch {
      rejectedRelativePath = true
    }
    XCTAssertTrue(rejectedRelativePath)

    #if !os(Windows)
      var metadata = stat()
      XCTAssertEqual(lstat(path + ".pre-v15", &metadata), 0)
      XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    #endif
  }

  private func makeVersionFourteenDatabase(at path: String) async throws {
    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL)")
      for version in 1...14 {
        try db.execute(
          sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
          arguments: ["BridgeServiceCore.v\(version)"]
        )
      }
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      try ServiceStoreSchema.createVersionSeven(in: db)
      try ServiceStoreSchema.createVersionEight(in: db)
      try ServiceStoreSchema.createVersionNine(in: db)
      try ServiceStoreSchema.createVersionTen(in: db)
      try ServiceStoreSchema.createVersionEleven(in: db)
      try ServiceStoreSchema.createVersionTwelve(in: db)
      try ServiceStoreSchema.createVersionThirteen(in: db)
      try ServiceStoreSchema.createVersionFourteen(in: db)
      try Self.insertLegacyRows(in: db)
    }
  }

  private static func insertLegacyRows(in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_projects (
          project_id, name, canonical_path, root_device, root_inode,
          read_permission, write_permission, network_permission,
          direct_command_mode, workspace_commands_json, direct_blacklist_json,
          created_at, updated_at
        ) VALUES ('prj-v14', 'Legacy', '/tmp/v14', '1', '2',
          'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
          CAST('[]' AS BLOB), 1, 2)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_tasks (
          task_id, project_id, source, source_client_id, prompt, status,
          supervisor_status, execution_model, execution_effort, permission_mode,
          network_allowed, access_mode, fast_mode, changed_files_json,
          created_at, updated_at, provider_id, selection_mode
        ) VALUES ('tsk-v14', 'prj-v14', 'mcp.client', 'qwen.studio', 'Legacy',
          'completed', 'disabled', 'legacy-model', 'medium', 'read-only', 0,
          'request-approval', 0, CAST('[]' AS BLOB), 1, 2, 'codex', 'legacy_codex')
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_events (task_id, kind, summary, created_at)
        VALUES ('tsk-v14', 'task.created', 'Preserved event', 3)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_messages (
          task_id, message_key, role, content, created_at, kind, updated_at
        ) VALUES ('tsk-v14', 'agent:1', 'agent', 'Preserved message', 4, 'agent', 4)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_installations (
          installation_id, provider_id, display_name, executable_path,
          canonical_executable_path, executable_device, executable_inode,
          executable_size, executable_mtime_ns, executable_sha256, version,
          protocol_revision, adapter_revision, trust_profile, security_profile_id,
          is_enabled, availability, capabilities_json, last_probe_error,
          last_probed_at, created_at, updated_at
        ) VALUES ('ainst-v14', 'open_code', 'Legacy', '/tmp/opencode', '/tmp/opencode',
          '1', '2', '3', 4, ?, '1', '1', 1, 'managed', NULL, 1, 'unavailable',
          CAST('{}' AS BLOB), NULL, NULL, 1, 2)
        """,
      arguments: [String(repeating: "0", count: 64)]
    )
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_installation_artifacts (
          installation_id, role, canonical_path, artifact_device, artifact_inode,
          artifact_size, artifact_mtime_ns, artifact_sha256, created_at, updated_at
        ) VALUES ('ainst-v14', 'launch_configuration', '/tmp/v14-config', '1', '2',
          '3', 4, ?, 1, 2)
        """,
      arguments: [String(repeating: "0", count: 64)]
    )
  }
}
