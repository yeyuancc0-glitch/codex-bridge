import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import CryptoKit
import Foundation
import GRDB

struct LegacyRepositoryReadResult: Sendable {
  let projects: [ServiceProjectRecord]
  let reducedProjects: [LegacyProjectReduction]
}

struct LegacyRepositoryReader {
  static let maximumProjectBytes = 256 * 1_024
  static let maximumProjects = 10_000

  let file: LegacyVerifiedSourceFile
  let importDate: Date

  func read() throws -> LegacyRepositoryReadResult {
    try withExtendedLifetime(file) {
      try readValidatedFile()
    }
  }

  private func readValidatedFile() throws -> LegacyRepositoryReadResult {
    try file.validateUnchanged()

    var configuration = Configuration()
    configuration.readonly = true
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    let database: DatabaseQueue
    do {
      database = try DatabaseQueue(
        path: file.descriptorPath,
        configuration: configuration
      )
    } catch {
      try file.validateUnchanged()
      throw LegacyImportError.readFailed
    }
    var databaseClosed = false
    defer {
      if !databaseClosed {
        try? database.close()
      }
    }
    try file.validateUnchanged()

    let readResult: Result<LegacyRepositoryReadResult, Error>
    do {
      readResult = .success(
        try database.read { db in
          try validateSchema(db)
          let count =
            try Int.fetchOne(
              db,
              sql: "SELECT COUNT(*) FROM bridge_repository_projects"
            ) ?? 0
          guard count <= Self.maximumProjects else {
            throw LegacyImportError.projectLimitExceeded
          }
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT project_id, configuration_json, configuration_sha256
              FROM bridge_repository_projects
              ORDER BY created_at, project_id
              """
          )
          var projects: [ServiceProjectRecord] = []
          var reductions: [LegacyProjectReduction] = []
          projects.reserveCapacity(rows.count)
          reductions.reserveCapacity(rows.count)
          for row in rows {
            let project = try decodeProject(row)
            try validateStoredRoots(of: project, in: db)
            let migrated = try migrate(project)
            projects.append(migrated.project)
            if let reduction = migrated.reduction {
              reductions.append(reduction)
            }
          }
          return LegacyRepositoryReadResult(
            projects: projects,
            reducedProjects: reductions
          )
        }
      )
    } catch {
      readResult = .failure(error)
    }

    do {
      try database.close()
      databaseClosed = true
    } catch {
      throw LegacyImportError.readFailed
    }
    try file.validateUnchanged()
    switch readResult {
    case .success(let result):
      return result
    case .failure(let error as LegacyImportError):
      throw error
    case .failure:
      throw LegacyImportError.corruptRepository
    }
  }

  private func validateSchema(_ db: Database) throws {
    let journalMode = try String.fetchOne(
      db,
      sql: "PRAGMA journal_mode"
    )?.lowercased()
    guard journalMode == "delete" else {
      throw LegacyImportError.unsupportedRepositorySchema
    }

    let tables = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name GLOB 'bridge_repository_*'
        ORDER BY name
        """
    )
    let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
    guard quickCheck == "ok",
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
      try Int64.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_repository_meta WHERE singleton = 1"
      ) == 1
    else {
      throw LegacyImportError.corruptRepository
    }

    let requiredColumns: [String: Set<String>] = [
      "bridge_repository_meta": ["singleton", "schema_version"],
      "bridge_repository_projects": [
        "project_id", "configuration_json", "configuration_sha256", "created_at",
      ],
      "bridge_repository_project_roots": [
        "project_id", "role", "ordinal", "canonical_path", "device", "inode",
      ],
      "bridge_repository_thread_bindings": [
        "thread_id", "project_id", "canonical_path", "device", "inode", "bound_at",
      ],
      "bridge_repository_final_reports": [
        "task_id", "schema_version", "status", "project_name", "thread_id", "stored_at",
        "report_json", "report_sha256",
      ],
    ]
    guard Set(tables) == Set(requiredColumns.keys) else {
      throw LegacyImportError.unsupportedRepositorySchema
    }
    for (table, expected) in requiredColumns {
      guard Set(try db.columns(in: table).map(\.name)) == expected else {
        throw LegacyImportError.unsupportedRepositorySchema
      }
    }

    guard try db.tableExists("grdb_migrations") else {
      throw LegacyImportError.unsupportedRepositorySchema
    }
    let migrations = try String.fetchAll(
      db,
      sql: """
        SELECT identifier FROM grdb_migrations
        WHERE identifier LIKE 'BridgeRepositories.%'
        """
    )
    guard Set(migrations) == ["BridgeRepositories.v1"] else {
      throw LegacyImportError.unsupportedRepositorySchema
    }
  }

  private func decodeProject(_ row: Row) throws -> RegisteredProject {
    let expectedID: String = row["project_id"]
    let data: Data = row["configuration_json"]
    let expectedDigest: Data = row["configuration_sha256"]
    guard !expectedID.isEmpty,
      data.count <= Self.maximumProjectBytes,
      expectedDigest.count == 32,
      expectedDigest == Data(SHA256.hash(data: data))
    else {
      throw LegacyImportError.corruptRepository
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let envelope: LegacyProjectEnvelope
    do {
      envelope = try decoder.decode(LegacyProjectEnvelope.self, from: data)
    } catch {
      throw LegacyImportError.corruptRepository
    }
    guard envelope.schemaVersion == 1,
      envelope.project.id.rawValue == expectedID,
      try canonicalData(envelope) == data
    else {
      throw LegacyImportError.corruptRepository
    }
    return envelope.project
  }

  private func validateStoredRoots(
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
    let expected =
      [(role: "primary", ordinal: 0, root: project.primaryRoot)]
      + project.worktreeRoots.enumerated().map {
        (role: "worktree", ordinal: $0.offset, root: $0.element)
      }
    guard rows.count == expected.count else {
      throw LegacyImportError.corruptRepository
    }
    for (row, entry) in zip(rows, expected) {
      let role: String = row["role"]
      let ordinal: Int = row["ordinal"]
      let path: String = row["canonical_path"]
      let device: String = row["device"]
      let inode: String = row["inode"]
      guard role == entry.role,
        ordinal == entry.ordinal,
        path == entry.root.canonicalPath,
        device == String(entry.root.identity.device),
        inode == String(entry.root.identity.inode)
      else {
        throw LegacyImportError.corruptRepository
      }
    }
  }

  private func migrate(
    _ project: RegisteredProject
  ) throws -> (project: ServiceProjectRecord, reduction: LegacyProjectReduction?) {
    let migrated: ServiceProjectRecord
    do {
      migrated = try ServiceProjectRecord(
        id: project.id,
        name: project.name,
        root: ServiceRootIdentity(
          canonicalPath: project.primaryRoot.canonicalPath,
          device: project.primaryRoot.identity.device,
          inode: project.primaryRoot.identity.inode
        ),
        accessPolicy: project.accessPolicy,
        createdAt: project.createdAt,
        updatedAt: max(project.createdAt, importDate)
      )
    } catch {
      throw LegacyImportError.unsupportedProject(project.id)
    }

    let repositoryRootWasDifferent = project.primaryRoot != project.repositoryRoot
    let reduction =
      project.worktreeRoots.isEmpty && !repositoryRootWasDifferent
      ? nil
      : LegacyProjectReduction(
        projectID: project.id,
        omittedWorktreeCount: project.worktreeRoots.count,
        repositoryRootWasDifferent: repositoryRootWasDifferent
      )
    return (migrated, reduction)
  }

  private func canonicalData(_ envelope: LegacyProjectEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(envelope)
  }
}

private struct LegacyProjectEnvelope: Codable, Equatable, Sendable {
  let schemaVersion: Int64
  let project: RegisteredProject
}
