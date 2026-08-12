import BridgeDomain
import BridgeExecution
import BridgeProjects
import BridgeSecurity
import Foundation
import GRDB

extension ApplicationRepository {
  public func storeBinding(_ binding: ThreadProjectBindingRecord) throws {
    try Self.validate(binding)
    try database.write { db in
      if let stored = try Self.fetchBinding(threadID: binding.threadID, in: db) {
        guard Self.sameBinding(stored, binding) else {
          throw ProjectExecutionError.threadAlreadyBound
        }
        return
      }
      guard
        try Self.rootIsRegistered(
          binding.root,
          projectID: binding.projectID,
          in: db
        )
      else {
        throw ApplicationRepositoryError.unregisteredBindingRoot
      }
      try Self.insertBinding(binding, in: db)
    }
  }

  public func storedBinding(for threadID: String) throws -> ThreadProjectBindingRecord? {
    try Self.validateIdentifier(threadID, field: "thread_id", maximum: 1_024)
    return try database.read { db in
      try Self.fetchBinding(threadID: threadID, in: db)
    }
  }

  public func binding(for threadID: String) throws -> ProjectThreadBinding? {
    guard let stored = try storedBinding(for: threadID) else { return nil }
    return ProjectThreadBinding(
      threadID: stored.threadID,
      projectID: stored.projectID,
      root: stored.root
    )
  }

  public func insert(_ binding: ProjectThreadBinding) throws {
    try storeBinding(
      ThreadProjectBindingRecord(
        threadID: binding.threadID,
        projectID: binding.projectID,
        root: binding.root,
        boundAt: Date()
      )
    )
  }

  static func rootIsRegistered(
    _ root: RegisteredRoot,
    projectID: ProjectID,
    in db: Database
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM bridge_repository_project_roots
          WHERE project_id = ? AND canonical_path = ? AND device = ? AND inode = ?
        )
        """,
      arguments: [
        projectID.rawValue,
        root.canonicalPath,
        String(root.identity.device),
        String(root.identity.inode),
      ]
    ) ?? false
  }

  static func insertBinding(
    _ binding: ThreadProjectBindingRecord,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_repository_thread_bindings (
            thread_id, project_id, canonical_path, device, inode, bound_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.threadID,
        binding.projectID.rawValue,
        binding.root.canonicalPath,
        String(binding.root.identity.device),
        String(binding.root.identity.inode),
        binding.boundAt.timeIntervalSince1970,
      ]
    )
  }

  static func fetchBinding(
    threadID: String,
    in db: Database
  ) throws -> ThreadProjectBindingRecord? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT thread_id, project_id, canonical_path, device, inode, bound_at
          FROM bridge_repository_thread_bindings WHERE thread_id = ?
          """,
        arguments: [threadID]
      )
    else { return nil }

    let projectID = ProjectID(rawValue: row["project_id"])
    guard let project = try fetchProject(id: projectID, in: db) else {
      throw ApplicationRepositoryError.corruptRecord("thread_binding.project")
    }
    let canonicalPath: String = row["canonical_path"]
    let device: String = row["device"]
    let inode: String = row["inode"]
    guard
      let root = allowedRoots(of: project).lazy.map(\.root).first(where: {
        $0.canonicalPath == canonicalPath
          && String($0.identity.device) == device
          && String($0.identity.inode) == inode
      })
    else {
      throw ApplicationRepositoryError.corruptRecord("thread_binding.root")
    }
    let timestamp: Double = row["bound_at"]
    guard timestamp.isFinite else {
      throw ApplicationRepositoryError.corruptRecord("thread_binding.bound_at")
    }
    return ThreadProjectBindingRecord(
      threadID: row["thread_id"],
      projectID: projectID,
      root: root,
      boundAt: Date(timeIntervalSince1970: timestamp)
    )
  }

  static func validate(_ binding: ThreadProjectBindingRecord) throws {
    try validateIdentifier(binding.threadID, field: "thread_id", maximum: 1_024)
    try validateIdentifier(binding.projectID.rawValue, field: "project_id", maximum: 256)
    try validate(binding.root, field: "binding_root")
    guard binding.boundAt.timeIntervalSince1970.isFinite else {
      throw ApplicationRepositoryError.invalidArgument("bound_at")
    }
  }

  static func sameBinding(
    _ lhs: ThreadProjectBindingRecord,
    _ rhs: ThreadProjectBindingRecord
  ) -> Bool {
    lhs.threadID == rhs.threadID && lhs.projectID == rhs.projectID && lhs.root == rhs.root
  }
}
