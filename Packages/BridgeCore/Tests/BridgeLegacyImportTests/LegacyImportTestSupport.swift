import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import CryptoKit
import Foundation
import GRDB
import XCTest

struct LegacyImportFixture {
  let root: URL
  let legacyRoot: URL
  let newDatabaseURL: URL
  let projectRoot: URL

  init(testCase: XCTestCase) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-legacy-import-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    legacyRoot = root.appending(path: "CodexBridge", directoryHint: .isDirectory)
    newDatabaseURL = root.appending(path: "service.sqlite", directoryHint: .notDirectory)
    projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
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

  func store() throws -> SimpleServiceStore {
    try SimpleServiceStore(path: newDatabaseURL.path)
  }

  func createDirectory(_ relativePath: String) throws -> URL {
    let url = root.appending(path: relativePath, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  func project(
    id: String,
    name: String = "Legacy Project",
    rootURL: URL? = nil,
    repositoryRootURL: URL? = nil,
    worktreeURLs: [URL] = [],
    policy: ProjectAccessPolicy = .init(),
    createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
  ) throws -> RegisteredProject {
    let primary = try RegisteredRoot(capturing: rootURL ?? projectRoot)
    let repository = try RegisteredRoot(capturing: repositoryRootURL ?? rootURL ?? projectRoot)
    let worktrees = try worktreeURLs.map(RegisteredRoot.init(capturing:))
    return RegisteredProject(
      id: ProjectID(rawValue: id),
      name: name,
      primaryRoot: primary,
      repositoryRoot: repository,
      worktreeRoots: worktrees,
      accessPolicy: policy,
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: createdAt
    )
  }

  func writeRepository(
    projects: [RegisteredProject],
    corruptDigestFor projectID: ProjectID? = nil
  ) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: repositoryURL.path, configuration: configuration)
    try database.write { db in
      try db.execute(sql: legacyRepositorySchema)
      for project in projects {
        let data = try legacyProjectData(project)
        let digest =
          project.id == projectID
          ? Data(repeating: 0, count: 32)
          : Data(SHA256.hash(data: data))
        try db.execute(
          sql: """
            INSERT INTO bridge_repository_projects (
              project_id, configuration_json, configuration_sha256, created_at
            ) VALUES (?, ?, ?, ?)
            """,
          arguments: [
            project.id.rawValue,
            data,
            digest,
            project.createdAt.timeIntervalSince1970,
          ]
        )
        try insertRoot(
          project.primaryRoot,
          projectID: project.id,
          role: "primary",
          ordinal: 0,
          in: db
        )
        for (index, worktree) in project.worktreeRoots.enumerated() {
          try insertRoot(
            worktree,
            projectID: project.id,
            role: "worktree",
            ordinal: index,
            in: db
          )
        }
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: repositoryURL.path
    )
  }

  func writeOnboarding(
    mode: String = "secureTunnel",
    tunnelID: String?
  ) throws {
    var object: [String: Any] = [
      "schemaVersion": 1,
      "connectionMode": mode,
    ]
    if let tunnelID {
      object["tunnelID"] = tunnelID
    }
    let data = try JSONSerialization.data(
      withJSONObject: object,
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

  private func insertRoot(
    _ root: RegisteredRoot,
    projectID: ProjectID,
    role: String,
    ordinal: Int,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_repository_project_roots (
          project_id, role, ordinal, canonical_path, device, inode
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        projectID.rawValue,
        role,
        ordinal,
        root.canonicalPath,
        String(root.identity.device),
        String(root.identity.inode),
      ]
    )
  }
}

private struct LegacyProjectEnvelopeFixture: Codable {
  let schemaVersion: Int64
  let project: RegisteredProject
}

private func legacyProjectData(_ project: RegisteredProject) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .millisecondsSince1970
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(
    LegacyProjectEnvelopeFixture(schemaVersion: 1, project: project)
  )
}

private let legacyRepositorySchema = """
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
