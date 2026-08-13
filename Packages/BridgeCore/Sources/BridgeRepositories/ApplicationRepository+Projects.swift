import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import GRDB

extension ApplicationRepository {
  public func allProjects() throws -> [RegisteredProject] {
    try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT project_id, configuration_json, configuration_sha256
          FROM bridge_repository_projects
          ORDER BY created_at, project_id
          """
      )
      return try rows.map { row in
        let project = try Self.decodeProject(
          row["configuration_json"],
          expectedID: row["project_id"],
          expectedDigest: row["configuration_sha256"]
        )
        try Self.validateStoredRoots(of: project, in: db)
        return project
      }
    }
  }

  public func project(id: ProjectID) throws -> RegisteredProject? {
    try Self.validateIdentifier(id.rawValue, field: "project_id", maximum: 256)
    return try database.read { db in
      try Self.fetchProject(id: id, in: db)
    }
  }

  public func insert(_ project: RegisteredProject) throws {
    try Self.validate(project)
    let encoded = try Self.encodeProject(project)
    let roots = Self.allowedRoots(of: project)

    return try database.write { db in
      if let stored = try Self.fetchProject(id: project.id, in: db) {
        guard stored == project else { throw ProjectRegistryError.duplicateProjectID }
        return
      }
      for (_, _, root) in roots {
        guard try !Self.containsRoot(root, in: db) else {
          throw ProjectRegistryError.duplicateRoot
        }
      }

      try db.execute(
        sql: """
          INSERT INTO bridge_repository_projects (
              project_id, configuration_json, configuration_sha256, created_at
          ) VALUES (?, ?, ?, ?)
          """,
        arguments: [
          project.id.rawValue,
          encoded,
          Self.digest(encoded),
          project.createdAt.timeIntervalSince1970,
        ]
      )
      for (role, ordinal, root) in roots {
        try Self.insertRoot(
          root,
          projectID: project.id,
          role: role,
          ordinal: ordinal,
          in: db
        )
      }
    }
  }

  public func addWorktree(_ root: RegisteredRoot, to projectID: ProjectID) throws {
    try Self.validateIdentifier(projectID.rawValue, field: "project_id", maximum: 256)
    try Self.validate(root, field: "worktree_root")

    try database.write { db in
      guard let project = try Self.fetchProject(id: projectID, in: db) else {
        throw ProjectRegistryError.unknownProject
      }
      if project.worktreeRoots.contains(root) { return }
      guard try !Self.containsRoot(root, in: db) else {
        throw ProjectRegistryError.duplicateRoot
      }

      let updated = project.addingWorktree(root)
      try Self.validate(updated)
      let encoded = try Self.encodeProject(updated)
      try db.execute(
        sql: """
          UPDATE bridge_repository_projects
          SET configuration_json = ?, configuration_sha256 = ?
          WHERE project_id = ?
          """,
        arguments: [encoded, Self.digest(encoded), projectID.rawValue]
      )
      try Self.insertRoot(
        root,
        projectID: projectID,
        role: "worktree",
        ordinal: project.worktreeRoots.count,
        in: db
      )
    }
  }

  public func updateAccessPolicy(
    _ policy: ProjectAccessPolicy,
    for projectID: ProjectID
  ) throws {
    try Self.validateIdentifier(projectID.rawValue, field: "project_id", maximum: 256)
    try database.write { db in
      guard let project = try Self.fetchProject(id: projectID, in: db) else {
        throw ProjectRegistryError.unknownProject
      }
      let updated = project.updatingAccessPolicy(policy)
      try Self.validate(updated)
      let encoded = try Self.encodeProject(updated)
      try db.execute(
        sql: """
          UPDATE bridge_repository_projects
          SET configuration_json = ?, configuration_sha256 = ?
          WHERE project_id = ?
          """,
        arguments: [encoded, Self.digest(encoded), projectID.rawValue]
      )
    }
  }

  static func fetchProject(id: ProjectID, in db: Database) throws -> RegisteredProject? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT project_id, configuration_json, configuration_sha256
          FROM bridge_repository_projects WHERE project_id = ?
          """,
        arguments: [id.rawValue]
      )
    else { return nil }
    let project = try decodeProject(
      row["configuration_json"],
      expectedID: row["project_id"],
      expectedDigest: row["configuration_sha256"]
    )
    try validateStoredRoots(of: project, in: db)
    return project
  }

  static func containsRoot(_ root: RegisteredRoot, in db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM bridge_repository_project_roots
          WHERE canonical_path = ? OR (device = ? AND inode = ?)
        )
        """,
      arguments: [
        root.canonicalPath,
        String(root.identity.device),
        String(root.identity.inode),
      ]
    ) ?? false
  }

  static func insertRoot(
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

  static func encodeProject(_ project: RegisteredProject) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      ProjectConfigurationEnvelope(schemaVersion: 1, project: project)
    )
    guard data.count <= maximumProjectJSONBytes else {
      throw ApplicationRepositoryError.limitExceeded(
        field: "project_configuration",
        maximum: maximumProjectJSONBytes
      )
    }
    return data
  }

  static func decodeProject(
    _ data: Data,
    expectedID: String,
    expectedDigest: Data
  ) throws -> RegisteredProject {
    guard data.count <= maximumProjectJSONBytes else {
      throw ApplicationRepositoryError.corruptRecord("project_configuration.bounds")
    }
    guard expectedDigest == digest(data) else {
      throw ApplicationRepositoryError.corruptRecord("project_configuration.checksum")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let envelope: ProjectConfigurationEnvelope
    do {
      envelope = try decoder.decode(ProjectConfigurationEnvelope.self, from: data)
    } catch {
      throw ApplicationRepositoryError.corruptRecord("project_configuration.json")
    }
    guard envelope.schemaVersion == 1 else {
      throw ApplicationRepositoryError.unsupportedSchemaVersion(envelope.schemaVersion)
    }
    guard envelope.project.id.rawValue == expectedID else {
      throw ApplicationRepositoryError.corruptRecord("project_configuration.id")
    }
    try validate(envelope.project)
    guard try encodeProject(envelope.project) == data else {
      throw ApplicationRepositoryError.corruptRecord("project_configuration.encoding")
    }
    return envelope.project
  }

  static func validateStoredRoots(
    of project: RegisteredProject,
    in db: Database
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT role, ordinal, canonical_path, device, inode
        FROM bridge_repository_project_roots
        WHERE project_id = ?
        ORDER BY CASE role WHEN 'primary' THEN 0 ELSE 1 END, ordinal
        """,
      arguments: [project.id.rawValue]
    )
    let expected = allowedRoots(of: project)
    guard rows.count == expected.count else {
      throw ApplicationRepositoryError.corruptRecord("project_roots.count")
    }
    for (row, root) in zip(rows, expected) {
      let role: String = row["role"]
      let ordinal: Int = row["ordinal"]
      let canonicalPath: String = row["canonical_path"]
      let device: String = row["device"]
      let inode: String = row["inode"]
      guard role == root.role, ordinal == root.ordinal,
        canonicalPath == root.root.canonicalPath,
        device == String(root.root.identity.device),
        inode == String(root.root.identity.inode)
      else {
        throw ApplicationRepositoryError.corruptRecord("project_roots.identity")
      }
    }
  }

  static func validate(_ project: RegisteredProject) throws {
    try validateIdentifier(project.id.rawValue, field: "project_id", maximum: 256)
    try validateIdentifier(project.name, field: "project_name", maximum: 400)
    guard project.createdAt.timeIntervalSince1970.isFinite else {
      throw ApplicationRepositoryError.invalidArgument("project_created_at")
    }
    guard project.worktreeRoots.count <= maximumWorktrees else {
      throw ApplicationRepositoryError.limitExceeded(
        field: "worktree_roots",
        maximum: maximumWorktrees
      )
    }
    guard project.verificationCommands.count <= maximumConfigurationItems else {
      throw ApplicationRepositoryError.limitExceeded(
        field: "verification_commands",
        maximum: maximumConfigurationItems
      )
    }
    guard project.forbiddenPatterns.count <= maximumConfigurationItems else {
      throw ApplicationRepositoryError.limitExceeded(
        field: "forbidden_patterns",
        maximum: maximumConfigurationItems
      )
    }
    for permission in [
      project.accessPolicy.read,
      project.accessPolicy.write,
      project.accessPolicy.network,
    ] {
      try validateIdentifier(permission.rawValue, field: "project_permission", maximum: 128)
    }
    try validate(project.primaryRoot, field: "primary_root")
    try validate(project.repositoryRoot, field: "repository_root")
    for root in project.worktreeRoots {
      try validate(root, field: "worktree_root")
    }
    guard
      contains(
        parent: project.repositoryRoot.canonicalPath, child: project.primaryRoot.canonicalPath)
    else {
      throw ProjectRegistryError.repositoryDoesNotContainProject
    }
    let roots = [project.primaryRoot] + project.worktreeRoots
    guard Set(roots.map(\.canonicalPath)).count == roots.count,
      Set(roots.map(\.identity)).count == roots.count
    else {
      throw ProjectRegistryError.duplicateRoot
    }
  }

  static func validate(_ root: RegisteredRoot, field: String) throws {
    let path = root.canonicalPath
    guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil,
      URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path
    else {
      throw ApplicationRepositoryError.invalidArgument(field)
    }
  }

  static func allowedRoots(of project: RegisteredProject) -> [RootEntry] {
    [("primary", 0, project.primaryRoot)]
      + project.worktreeRoots.enumerated().map { ("worktree", $0.offset, $0.element) }
  }

  static func contains(parent: String, child: String) -> Bool {
    child == parent || child.hasPrefix(parent + "/")
  }
}

struct ProjectConfigurationEnvelope: Codable, Equatable, Sendable {
  let schemaVersion: Int64
  let project: RegisteredProject
}

typealias RootEntry = (role: String, ordinal: Int, root: RegisteredRoot)
