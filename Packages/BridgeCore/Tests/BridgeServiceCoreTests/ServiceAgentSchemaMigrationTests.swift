import BridgeAgentCore
import BridgeDomain
import Darwin
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentSchemaMigrationTests: XCTestCase {
  func testVersionElevenAddsMessageActivityTimestampWithPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-message-schema-v12-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appending(path: "service.sqlite").path

    do {
      let legacy = try DatabaseQueue(path: databasePath)
      try await legacy.writeWithoutTransaction { db in
        try db.execute(
          sql: """
            CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
            INSERT INTO grdb_migrations (identifier) VALUES
              ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
              ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
              ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6'),
              ('BridgeServiceCore.v7'), ('BridgeServiceCore.v8'),
              ('BridgeServiceCore.v9'), ('BridgeServiceCore.v10'),
              ('BridgeServiceCore.v11');
            """)
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
        try db.execute(
          sql: """
            INSERT INTO bridge_service_projects (
              project_id, name, canonical_path, root_device, root_inode,
              read_permission, write_permission, network_permission, created_at, updated_at
            ) VALUES ('prj-v11', 'Legacy', '/tmp/v11', '1', '2',
              'allowed', 'allowed', 'denied', 1, 2);
            INSERT INTO bridge_service_tasks (
              task_id, project_id, source, source_client_id, prompt, status,
              supervisor_status, execution_model, execution_effort, permission_mode,
              network_allowed, access_mode, fast_mode, changed_files_json,
              created_at, updated_at
            ) VALUES ('tsk-v11', 'prj-v11', 'mcp.client', 'chatgpt', 'Legacy task',
              'completed', 'disabled', 'legacy-model', 'medium', 'read-only', 0,
              'request-approval', 0, CAST('[]' AS BLOB), 1, 2);
            INSERT INTO bridge_service_task_messages (
              task_id, message_key, role, kind, content, created_at
            ) VALUES ('tsk-v11', 'agent:1', 'agent', 'agent', 'Done.', 3);
            """)
      }
    }

    let store = try SimpleServiceStore(path: databasePath)
    let messages = try await store.taskMessages(taskID: TaskID(rawValue: "tsk-v11"))
    XCTAssertEqual(messages.first?.createdAt, Date(timeIntervalSince1970: 3))
    XCTAssertEqual(messages.first?.updatedAt, Date(timeIntervalSince1970: 3))

    let backupPath = databasePath + ".pre-v12"
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
    XCTAssertEqual(backupVersion, 11)
  }

  func testVersionNineMigratesToAgentInstallationsWithPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-schema-v10-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appending(path: "service.sqlite").path

    do {
      let legacy = try DatabaseQueue(path: databasePath)
      try await legacy.writeWithoutTransaction { db in
        try db.execute(
          sql: """
            CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
            INSERT INTO grdb_migrations (identifier) VALUES
              ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
              ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
              ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6'),
              ('BridgeServiceCore.v7'), ('BridgeServiceCore.v8'),
              ('BridgeServiceCore.v9');
            """
        )
        try ServiceStoreSchema.createVersionOne(in: db)
        try ServiceStoreSchema.createVersionTwo(in: db)
        try ServiceStoreSchema.createVersionThree(in: db)
        try ServiceStoreSchema.createVersionFour(in: db)
        try ServiceStoreSchema.createVersionFive(in: db)
        try ServiceStoreSchema.createVersionSix(in: db)
        try ServiceStoreSchema.createVersionSeven(in: db)
        try ServiceStoreSchema.createVersionEight(in: db)
        try ServiceStoreSchema.createVersionNine(in: db)
      }
    }

    let store = try SimpleServiceStore(path: databasePath)
    let schema = try await store.database.read { db in
      let version = try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      let exists = try db.tableExists("bridge_service_agent_installations")
      return (version, exists)
    }
    XCTAssertEqual(schema.0, 12)
    XCTAssertTrue(schema.1)

    let backupPath = databasePath + ".pre-v10"
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
    XCTAssertEqual(backupVersion, 9)
  }

  func testAgentInstallationCRUDSurvivesRestart() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executableURL = fixture.rootURL.appending(path: "registered-agent")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let identity = try ServiceAgentExecutableIdentity(capturing: executableURL.path)
    let capabilities: Set<AgentCapability> = [
      .interrupt,
      .sessionCreate,
      .workspaceRead,
    ]
    let createdAt = Date(timeIntervalSince1970: 1_800_001_000)
    let probedAt = createdAt.addingTimeInterval(1)
    let record = try ServiceAgentInstallationRecord(
      id: AgentInstallationID(rawValue: "ainst-persisted"),
      providerID: .openCode,
      displayName: "Persisted OpenCode",
      executablePath: executableURL.path,
      executableIdentity: identity,
      version: "1.18.22",
      protocolRevision: "1",
      adapterRevision: 1,
      trustProfile: .managed,
      securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
      isEnabled: true,
      availability: .available,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      ),
      lastProbedAt: probedAt,
      createdAt: createdAt,
      updatedAt: probedAt
    )

    let store = try SimpleServiceStore(path: fixture.databasePath)
    try await store.insertAgentInstallation(record)
    let disabled = try record.replacingEnabled(
      false,
      updatedAt: probedAt.addingTimeInterval(1)
    )
    try await store.updateAgentInstallation(disabled)

    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let persisted = try await reopened.agentInstallation(id: record.id)
    let installations = try await reopened.agentInstallations(providerID: .openCode)
    XCTAssertEqual(persisted, disabled)
    XCTAssertEqual(installations, [disabled])

    try await reopened.removeAgentInstallation(id: record.id)
    let removed = try await reopened.agentInstallation(id: record.id)
    XCTAssertNil(removed)
  }
}
