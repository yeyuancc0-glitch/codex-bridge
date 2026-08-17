import BridgeCodexRPC
import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceHost
import CryptoKit
import Foundation
import GRDB
import XCTest

struct ServiceLegacyImportFixture {
  let root: URL
  let legacyRoot: URL
  let serviceRoot: URL
  let projectRoot: URL

  init(testCase: XCTestCase) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-service-legacy-import-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    legacyRoot = root.appending(path: "CodexBridge", directoryHint: .isDirectory)
    serviceRoot = root.appending(path: "CodexBridgeService", directoryHint: .isDirectory)
    projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(
      at: legacyRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: legacyRoot.path
    )
    try FileManager.default.createDirectory(
      at: projectRoot,
      withIntermediateDirectories: false
    )

    let cleanupURL = root
    testCase.addTeardownBlock {
      try? FileManager.default.removeItem(at: cleanupURL)
    }
  }

  var repositoryURL: URL {
    legacyRoot.appending(path: "application.sqlite", directoryHint: .notDirectory)
  }

  var onboardingURL: URL {
    legacyRoot.appending(path: "onboarding.json", directoryHint: .notDirectory)
  }

  func project(
    id: String = "legacy-service-project",
    name: String = "Legacy Service Project",
    accessPolicy: ProjectAccessPolicy = ProjectAccessPolicy(
      read: .allowed,
      write: .requiresLocalApproval,
      network: .denied
    )
  ) throws -> RegisteredProject {
    let root = try RegisteredRoot(capturing: projectRoot)
    return RegisteredProject(
      id: ProjectID(rawValue: id),
      name: name,
      primaryRoot: root,
      repositoryRoot: root,
      worktreeRoots: [],
      accessPolicy: accessPolicy,
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  func writeRepository(project: RegisteredProject) throws {
    do {
      var configuration = Configuration()
      configuration.foreignKeysEnabled = true
      let database = try DatabaseQueue(path: repositoryURL.path, configuration: configuration)
      try database.write { db in
        try db.execute(sql: serviceLegacyRepositorySchema)
        let data = try serviceLegacyProjectData(project)
        try db.execute(
          sql: """
            INSERT INTO bridge_repository_projects (
              project_id, configuration_json, configuration_sha256, created_at
            ) VALUES (?, ?, ?, ?)
            """,
          arguments: [
            project.id.rawValue,
            data,
            Data(SHA256.hash(data: data)),
            project.createdAt.timeIntervalSince1970,
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO bridge_repository_project_roots (
              project_id, role, ordinal, canonical_path, device, inode
            ) VALUES (?, 'primary', 0, ?, ?, ?)
            """,
          arguments: [
            project.id.rawValue,
            project.primaryRoot.canonicalPath,
            String(project.primaryRoot.identity.device),
            String(project.primaryRoot.identity.inode),
          ]
        )
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: repositoryURL.path
    )
  }

  func writeOnboarding(tunnelID: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "connectionMode": "secureTunnel",
        "schemaVersion": 1,
        "tunnelID": tunnelID,
      ],
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: onboardingURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: onboardingURL.path
    )
  }

  func digest(of url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url)))
  }

  func makeComposition(
    testCase: XCTestCase,
    legacyDataRootURL: URL?
  ) async throws -> (ServiceComposition, ServiceHostTestSecretStore) {
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    let secrets = ServiceHostTestSecretStore()
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.2.0",
        dataRootURL: serviceRoot,
        executionAppServer: unavailable,
        supervisorAppServer: unavailable,
        catalogAppServer: unavailable,
        clientInfo: .bridge(version: "legacy-service-tests"),
        appBundleURL: nil,
        legacyDataRootURL: legacyDataRootURL
      ),
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x5A, count: $0) }
    )
    testCase.addTeardownBlock {
      await composition.shutdown()
    }
    return (composition, secrets)
  }
}

private struct ServiceLegacyProjectEnvelope: Codable {
  let schemaVersion: Int64
  let project: RegisteredProject
}

private func serviceLegacyProjectData(_ project: RegisteredProject) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .millisecondsSince1970
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(
    ServiceLegacyProjectEnvelope(schemaVersion: 1, project: project)
  )
}

private let serviceLegacyRepositorySchema = """
  CREATE TABLE bridge_repository_meta (
    singleton INTEGER PRIMARY KEY NOT NULL,
    schema_version INTEGER NOT NULL
  ) WITHOUT ROWID;
  INSERT INTO bridge_repository_meta (singleton, schema_version) VALUES (1, 1);

  CREATE TABLE bridge_repository_projects (
    project_id TEXT PRIMARY KEY NOT NULL,
    configuration_json BLOB NOT NULL,
    configuration_sha256 BLOB NOT NULL,
    created_at REAL NOT NULL
  ) WITHOUT ROWID;

  CREATE TABLE bridge_repository_project_roots (
    project_id TEXT NOT NULL,
    role TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    canonical_path TEXT NOT NULL,
    device TEXT NOT NULL,
    inode TEXT NOT NULL,
    PRIMARY KEY (project_id, role, ordinal),
    UNIQUE (canonical_path),
    UNIQUE (device, inode),
    FOREIGN KEY (project_id) REFERENCES bridge_repository_projects(project_id)
  ) WITHOUT ROWID;

  CREATE TABLE bridge_repository_thread_bindings (
    thread_id TEXT PRIMARY KEY NOT NULL,
    project_id TEXT NOT NULL,
    canonical_path TEXT NOT NULL,
    device TEXT NOT NULL,
    inode TEXT NOT NULL,
    bound_at REAL NOT NULL
  ) WITHOUT ROWID;

  CREATE TABLE bridge_repository_final_reports (
    task_id TEXT PRIMARY KEY NOT NULL,
    schema_version INTEGER NOT NULL,
    status TEXT NOT NULL,
    project_name TEXT NOT NULL,
    thread_id TEXT NOT NULL,
    stored_at REAL NOT NULL,
    report_json BLOB NOT NULL,
    report_sha256 BLOB NOT NULL
  ) WITHOUT ROWID;

  CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
  INSERT INTO grdb_migrations (identifier) VALUES ('BridgeRepositories.v1');
  """
