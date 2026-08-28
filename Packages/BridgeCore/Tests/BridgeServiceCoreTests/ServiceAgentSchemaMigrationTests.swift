import BridgeAgentCore
import BridgeDomain
import Darwin
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentSchemaMigrationTests: XCTestCase {
  func testVersionThirteenAcceptsDeclinedAndCancelledToolMessagesAfterMigration()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-message-schema-v14-\(UUID().uuidString)",
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
              ('BridgeServiceCore.v11'), ('BridgeServiceCore.v12'),
              ('BridgeServiceCore.v13');
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
        try ServiceStoreSchema.createVersionTwelve(in: db)
        try ServiceStoreSchema.createVersionThirteen(in: db)
        try db.execute(
          sql: """
            INSERT INTO bridge_service_projects (
              project_id, name, canonical_path, root_device, root_inode,
              read_permission, write_permission, network_permission, created_at, updated_at
            ) VALUES ('prj-v13', 'Legacy', '/tmp/v13', '1', '2',
              'allowed', 'allowed', 'denied', 1, 2);
            INSERT INTO bridge_service_tasks (
              task_id, project_id, source, source_client_id, prompt, status,
              supervisor_status, execution_model, execution_effort, permission_mode,
              network_allowed, access_mode, fast_mode, changed_files_json,
              created_at, updated_at
            ) VALUES ('tsk-v13', 'prj-v13', 'mcp.client', 'chatgpt', 'Legacy task',
              'running', 'disabled', 'legacy-model', 'medium', 'read-only', 0,
              'request-approval', 0, CAST('[]' AS BLOB), 1, 2);
            INSERT INTO bridge_service_task_messages (
              task_id, message_key, role, kind, content, tool_name, tool_status,
              created_at, updated_at
            ) VALUES (
              'tsk-v13', 'tool:existing', 'agent', 'tool_call', 'Read file',
              'view_file', 'completed', 3, 3
            );
            """)
      }
    }

    let store = try SimpleServiceStore(path: databasePath)
    for status in ["declined", "cancelled"] {
      let message = try ServiceTaskMessageDraft(
        key: "tool:\(status)",
        role: .agent,
        content: "Tool \(status)",
        createdAt: Date(timeIntervalSince1970: 4),
        kind: .toolCall,
        toolName: "run_command",
        toolStatus: status
      )
      try await store.upsertTaskMessage(message, taskID: TaskID(rawValue: "tsk-v13"))
    }
    let messages = try await store.taskMessages(taskID: TaskID(rawValue: "tsk-v13"))
    XCTAssertEqual(messages.map(\.toolStatus), ["completed", "declined", "cancelled"])

    let backupPath = databasePath + ".pre-v14"
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
    XCTAssertEqual(backupVersion, 13)
  }

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
    XCTAssertEqual(schema.0, 14)
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

  func testVersionTwelveMigratesInstallationArtifactsWithPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-artifacts-v13-\(UUID().uuidString)",
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
              ('BridgeServiceCore.v11'), ('BridgeServiceCore.v12');
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
        try ServiceStoreSchema.createVersionTwelve(in: db)
      }
    }

    let store = try SimpleServiceStore(path: databasePath)
    let result = try await store.database.read { db in
      let version = try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      let columns = Set(
        try db.columns(in: "bridge_service_agent_installation_artifacts").map(\.name)
      )
      let foreignKeys = try Row.fetchAll(
        db,
        sql: "PRAGMA foreign_key_list(bridge_service_agent_installation_artifacts)"
      )
      return (version, columns, foreignKeys.count)
    }
    XCTAssertEqual(result.0, 14)
    XCTAssertEqual(
      result.1,
      [
        "installation_id", "role", "canonical_path", "artifact_device", "artifact_inode",
        "artifact_size", "artifact_mtime_ns", "artifact_sha256", "created_at", "updated_at",
      ]
    )
    XCTAssertEqual(result.2, 1)

    let backupPath = databasePath + ".pre-v13"
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
    XCTAssertEqual(backupVersion, 12)
  }

  func testInstallationArtifactIdentityAndForeignKeyCascade() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executableURL = fixture.rootURL.appending(path: "registered-agent")
    let configurationURL = fixture.rootURL.appending(path: "cordis.yml")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try Data("sandbox: read-only\n".utf8).write(to: configurationURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    XCTAssertEqual(chmod(configurationURL.path, 0o600), 0)

    let capturedAt = Date(timeIntervalSince1970: 1_800_002_000)
    let executableIdentity = try ServiceAgentExecutableIdentity(capturing: executableURL.path)
    let configurationIdentity = try ServiceAgentFileIdentity(
      capturing: configurationURL.path,
      role: .launchConfiguration
    )
    let artifacts = [
      try ServiceAgentInstallationArtifact(
        role: .launchConfiguration,
        identity: configurationIdentity,
        createdAt: capturedAt,
        updatedAt: capturedAt
      )
    ]
    let record = try ServiceAgentInstallationRecord(
      id: AgentInstallationID(rawValue: "ainst-artifacts"),
      providerID: .openCode,
      displayName: "OpenCode",
      executablePath: executableURL.path,
      executableIdentity: executableIdentity,
      version: "1.18.22",
      protocolRevision: "1",
      adapterRevision: 1,
      trustProfile: .managed,
      securityProfileID: nil,
      isEnabled: true,
      availability: .available,
      capabilities: AgentCapabilitySnapshot(
        advertised: [.sessionCreate],
        observed: [.sessionCreate],
        enforced: [.sessionCreate]
      ),
      artifacts: artifacts,
      lastProbedAt: capturedAt,
      createdAt: capturedAt,
      updatedAt: capturedAt
    )

    let store = try SimpleServiceStore(path: fixture.databasePath)
    try await store.insertAgentInstallation(record)
    let persistedArtifacts = try await store.agentInstallationArtifacts(for: record.id)
    XCTAssertEqual(persistedArtifacts, artifacts)
    guard let installation = try await store.agentInstallation(id: record.id) else {
      return XCTFail("Expected the installation to persist")
    }
    XCTAssertEqual(installation.artifacts, artifacts)

    try await store.removeAgentInstallation(id: record.id)
    let artifactCount = try await store.database.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_service_agent_installation_artifacts
          WHERE installation_id = ?
          """,
        arguments: [record.id.rawValue]
      )
    }
    XCTAssertEqual(artifactCount, 0)
  }
}
