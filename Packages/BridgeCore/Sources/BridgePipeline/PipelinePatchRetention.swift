import BridgeDomain
import BridgeGit
import Crypto
import Foundation
import GRDB

extension PipelineArtifactStore {
  public static let maximumRetentionScopeCount = 128

  public func patchReleaseManifest(for taskID: TaskID) throws
    -> PipelinePatchReleaseManifest?
  {
    try database.read { db in
      try Self.fetchPatchReleaseManifest(taskID: taskID, in: db)
    }
  }

  @discardableResult
  public func pruneTerminalScopes(
    for taskID: TaskID,
    maximumScopeCount: Int = maximumRetentionScopeCount,
    at date: Date = Date()
  ) throws -> PipelinePatchReleaseManifest? {
    guard (1...Self.maximumRetentionScopeCount).contains(maximumScopeCount) else {
      throw PipelineArtifactStoreError.invalidArgument("maximumScopeCount")
    }
    guard date.timeIntervalSince1970.isFinite else {
      throw PipelineArtifactStoreError.invalidArgument("date")
    }
    return try database.write { db in
      if let existing = try Self.fetchPatchReleaseManifest(taskID: taskID, in: db) {
        return existing
      }
      let scopeRows = try Row.fetchAll(
        db,
        sql: """
          SELECT task_id, generation, project_id, thread_id, turn_id, event_sequence, stage
          FROM bridge_pipeline_scopes
          WHERE task_id = ?
          ORDER BY generation
          LIMIT ?
          """,
        arguments: [taskID.rawValue, maximumScopeCount + 1]
      )
      guard scopeRows.count <= maximumScopeCount else {
        throw PipelineArtifactStoreError.limitExceeded(
          field: "retentionScopes",
          maximum: maximumScopeCount
        )
      }
      guard !scopeRows.isEmpty else { return nil }
      let scopes = try scopeRows.map { row -> TaskEvidenceScope in
        guard let stage = PipelineStage(rawValue: row["stage"]), stage.isTerminal else {
          throw PipelineArtifactStoreError.retentionRequiresTerminalScopes(taskID)
        }
        return try TaskEvidenceScope(
          taskID: TaskID(rawValue: row["task_id"]),
          projectID: ProjectID(rawValue: row["project_id"]),
          threadID: ThreadID(rawValue: row["thread_id"]),
          turnID: TurnID(rawValue: row["turn_id"]),
          generation: row["generation"],
          eventSequence: row["event_sequence"]
        )
      }
      try Self.ensurePatchReferences(for: scopes, maximum: maximumScopeCount, in: db)
      let patches = try Self.releasablePatches(
        taskID: taskID,
        maximum: maximumScopeCount,
        in: db
      )
      let manifest = try Self.makePatchReleaseManifest(
        taskID: taskID,
        patches: patches,
        createdAt: date
      )
      try Self.insert(manifest, in: db)
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_current_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_artifacts WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_patch_references WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      for patch in patches {
        try db.execute(
          sql: """
            DELETE FROM bridge_pipeline_patch_documents
            WHERE handle_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM bridge_pipeline_patch_references WHERE handle_id = ?
              )
            """,
          arguments: [patch.rawValue, patch.rawValue]
        )
        guard db.changesCount == 1 else {
          throw PipelineArtifactStoreError.retentionManifestConflict(taskID)
        }
      }
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      return manifest
    }
  }

  @discardableResult
  public func acknowledgePatchRelease(_ manifest: PipelinePatchReleaseManifest) throws -> Bool {
    try database.write { db in
      guard let stored = try Self.fetchPatchReleaseManifest(taskID: manifest.taskID, in: db)
      else { return false }
      guard stored == manifest else {
        throw PipelineArtifactStoreError.retentionManifestConflict(manifest.taskID)
      }
      for patch in stored.patches {
        let referenced =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS (
                SELECT 1 FROM bridge_pipeline_patch_references WHERE handle_id = ?
              )
              """,
            arguments: [patch.rawValue]
          ) ?? false
        guard !referenced else {
          throw PipelineArtifactStoreError.retentionManifestConflict(manifest.taskID)
        }
      }
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_patch_release_items WHERE task_id = ?",
        arguments: [manifest.taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_pipeline_patch_release_manifests WHERE task_id = ?",
        arguments: [manifest.taskID.rawValue]
      )
      guard db.changesCount == 1 else {
        throw PipelineArtifactStoreError.retentionManifestConflict(manifest.taskID)
      }
      return true
    }
  }

  private static func ensurePatchReferences(
    for scopes: [TaskEvidenceScope],
    maximum: Int,
    in db: Database
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT task_id, generation, payload_json, payload_sha256
        FROM bridge_pipeline_artifacts
        WHERE task_id = ? AND kind_category = 'git_final' AND kind_key = ''
        ORDER BY generation
        LIMIT ?
        """,
      arguments: [scopes[0].taskID.rawValue, maximum + 1]
    )
    guard rows.count <= maximum else {
      throw PipelineArtifactStoreError.limitExceeded(
        field: "retentionPatchReferences",
        maximum: maximum
      )
    }
    let scopesByGeneration = Dictionary(uniqueKeysWithValues: scopes.map { ($0.generation, $0) })
    for row in rows {
      let generation: Int64 = row["generation"]
      guard let scope = scopesByGeneration[generation] else {
        throw PipelineArtifactStoreError.corruptRecord
      }
      try PipelinePatchReferencePersistence.ensureReference(
        payload: row["payload_json"],
        expectedDigest: row["payload_sha256"],
        scope: scope,
        in: db
      )
    }
    let orphanReference =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1
            FROM bridge_pipeline_patch_references AS reference
            LEFT JOIN bridge_pipeline_artifacts AS artifact
              ON artifact.task_id = reference.task_id
             AND artifact.generation = reference.generation
             AND artifact.kind_category = 'git_final'
             AND artifact.kind_key = ''
            WHERE reference.task_id = ? AND artifact.task_id IS NULL
          )
          """,
        arguments: [scopes[0].taskID.rawValue]
      ) ?? false
    guard !orphanReference else { throw PipelineArtifactStoreError.corruptRecord }
  }

  private static func releasablePatches(
    taskID: TaskID,
    maximum: Int,
    in db: Database
  ) throws -> [GitPatchHandle] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT document.handle_id, document.total_bytes, document.is_truncated
        FROM bridge_pipeline_patch_references AS owned
        JOIN bridge_pipeline_patch_documents AS document
          ON document.handle_id = owned.handle_id
        WHERE owned.task_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM bridge_pipeline_patch_references AS other
            WHERE other.handle_id = owned.handle_id AND other.task_id <> ?
          )
        ORDER BY document.handle_id
        LIMIT ?
        """,
      arguments: [taskID.rawValue, taskID.rawValue, maximum + 1]
    )
    guard rows.count <= maximum else {
      throw PipelineArtifactStoreError.limitExceeded(
        field: "retentionPatchReferences",
        maximum: maximum
      )
    }
    let patches = try rows.map { row -> GitPatchHandle in
      let patch = GitPatchHandle(
        rawValue: row["handle_id"],
        totalBytes: row["total_bytes"],
        isTruncated: row["is_truncated"]
      )
      do {
        try GitPatchStore.validate(patch)
      } catch {
        throw PipelineArtifactStoreError.corruptRecord
      }
      return patch
    }
    for patch in patches {
      let pending =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM bridge_pipeline_patch_release_items WHERE handle_id = ?
            )
            """,
          arguments: [patch.rawValue]
        ) ?? false
      guard !pending else {
        throw PipelineArtifactStoreError.patchReleasePending(patch.rawValue)
      }
    }
    return patches
  }

  private static func insert(_ manifest: PipelinePatchReleaseManifest, in db: Database) throws {
    guard let digest = Data(hexadecimal: manifest.sha256) else {
      throw PipelineArtifactStoreError.retentionManifestConflict(manifest.taskID)
    }
    try db.execute(
      sql: """
        INSERT INTO bridge_pipeline_patch_release_manifests (
          task_id, created_at, manifest_sha256
        ) VALUES (?, ?, ?)
        """,
      arguments: [manifest.taskID.rawValue, manifest.createdAt.timeIntervalSince1970, digest]
    )
    for patch in manifest.patches {
      try db.execute(
        sql: """
          INSERT INTO bridge_pipeline_patch_release_items (
            task_id, handle_id, total_bytes, is_truncated
          ) VALUES (?, ?, ?, ?)
          """,
        arguments: [
          manifest.taskID.rawValue, patch.rawValue, patch.totalBytes, patch.isTruncated,
        ]
      )
    }
  }

  private static func fetchPatchReleaseManifest(taskID: TaskID, in db: Database) throws
    -> PipelinePatchReleaseManifest?
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT created_at, manifest_sha256
          FROM bridge_pipeline_patch_release_manifests WHERE task_id = ?
          """,
        arguments: [taskID.rawValue]
      )
    else { return nil }
    let timestamp: Double = row["created_at"]
    let storedDigest: Data = row["manifest_sha256"]
    guard timestamp.isFinite, storedDigest.count == 32 else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    let itemRows = try Row.fetchAll(
      db,
      sql: """
        SELECT handle_id, total_bytes, is_truncated
        FROM bridge_pipeline_patch_release_items
        WHERE task_id = ? ORDER BY handle_id LIMIT ?
        """,
      arguments: [taskID.rawValue, maximumRetentionScopeCount + 1]
    )
    guard itemRows.count <= maximumRetentionScopeCount else {
      throw PipelineArtifactStoreError.limitExceeded(
        field: "retentionPatchReferences",
        maximum: maximumRetentionScopeCount
      )
    }
    let patches = try itemRows.map { item -> GitPatchHandle in
      let patch = GitPatchHandle(
        rawValue: item["handle_id"],
        totalBytes: item["total_bytes"],
        isTruncated: item["is_truncated"]
      )
      do {
        try GitPatchStore.validate(patch)
      } catch {
        throw PipelineArtifactStoreError.corruptRecord
      }
      return patch
    }
    let manifest = try makePatchReleaseManifest(
      taskID: taskID,
      patches: patches,
      createdAt: Date(timeIntervalSince1970: timestamp)
    )
    guard storedDigest == Data(hexadecimal: manifest.sha256) else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    return manifest
  }

  private static func makePatchReleaseManifest(
    taskID: TaskID,
    patches: [GitPatchHandle],
    createdAt: Date
  ) throws -> PipelinePatchReleaseManifest {
    let sorted = patches.sorted { $0.rawValue < $1.rawValue }
    guard Set(sorted.map(\.rawValue)).count == sorted.count else {
      throw PipelineArtifactStoreError.retentionManifestConflict(taskID)
    }
    let payload = PatchReleaseManifestDigestPayload(
      taskID: taskID.rawValue,
      patches: sorted.map {
        .init(
          rawValue: $0.rawValue,
          totalBytes: $0.totalBytes,
          isTruncated: $0.isTruncated
        )
      },
      createdAt: createdAt.timeIntervalSince1970
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(payload)
    let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    return PipelinePatchReleaseManifest(
      taskID: taskID,
      patches: sorted,
      createdAt: createdAt,
      sha256: digest
    )
  }
}

private struct PatchReleaseManifestDigestPayload: Encodable {
  struct Patch: Encodable {
    let rawValue: String
    let totalBytes: Int
    let isTruncated: Bool
  }

  let taskID: String
  let patches: [Patch]
  let createdAt: Double
}

extension Data {
  fileprivate init?(hexadecimal: String) {
    guard hexadecimal.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hexadecimal.count / 2)
    var index = hexadecimal.startIndex
    while index < hexadecimal.endIndex {
      let end = hexadecimal.index(index, offsetBy: 2)
      guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
      bytes.append(byte)
      index = end
    }
    self = Data(bytes)
  }
}
