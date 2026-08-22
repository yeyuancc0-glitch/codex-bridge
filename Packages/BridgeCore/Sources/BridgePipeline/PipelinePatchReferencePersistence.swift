import BridgeDomain
import BridgeGit
import Crypto
import Foundation
import GRDB

enum PipelinePatchReferencePersistence {
  static func patchHandle(
    payload: Data,
    expectedDigest: Data
  ) throws -> GitPatchHandle? {
    guard expectedDigest == digest(payload), (try? canonicalize(payload)) == payload,
      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else { throw PipelineArtifactStoreError.corruptRecord }
    guard let rawPatch = object["patch"] else { return nil }
    guard !(rawPatch is NSNull) else { return nil }
    guard let evidence = try? JSONDecoder().decode(GitFinalEvidence.self, from: payload),
      let handle = evidence.patch
    else { throw PipelineArtifactStoreError.corruptRecord }
    do {
      try GitPatchStore.validate(handle)
    } catch {
      throw PipelineArtifactStoreError.corruptRecord
    }
    return handle
  }

  static func register(
    _ handle: GitPatchHandle?,
    scope: TaskEvidenceScope,
    in db: Database
  ) throws {
    guard let handle else { return }
    do {
      try GitPatchStore.validate(handle)
    } catch {
      throw PipelineArtifactStoreError.patchReferenceConflict(scope.taskID)
    }
    let pending =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM bridge_pipeline_patch_release_items WHERE handle_id = ?
          )
          """,
        arguments: [handle.rawValue]
      ) ?? false
    guard !pending else {
      throw PipelineArtifactStoreError.patchReleasePending(handle.rawValue)
    }
    if let existing = try String.fetchOne(
      db,
      sql: """
        SELECT handle_id FROM bridge_pipeline_patch_references
        WHERE task_id = ? AND generation = ?
        """,
      arguments: [scope.taskID.rawValue, scope.generation]
    ) {
      guard existing == handle.rawValue else {
        throw PipelineArtifactStoreError.patchReferenceConflict(scope.taskID)
      }
      try validateDocument(handle, in: db, taskID: scope.taskID)
      return
    }
    try db.execute(
      sql: """
        INSERT INTO bridge_pipeline_patch_documents (
          handle_id, total_bytes, is_truncated
        ) VALUES (?, ?, ?)
        ON CONFLICT(handle_id) DO NOTHING
        """,
      arguments: [handle.rawValue, handle.totalBytes, handle.isTruncated]
    )
    try validateDocument(handle, in: db, taskID: scope.taskID)
    try db.execute(
      sql: """
        INSERT INTO bridge_pipeline_patch_references (task_id, generation, handle_id)
        VALUES (?, ?, ?)
        """,
      arguments: [scope.taskID.rawValue, scope.generation, handle.rawValue]
    )
  }

  static func ensureReference(
    payload: Data,
    expectedDigest: Data,
    scope: TaskEvidenceScope,
    in db: Database
  ) throws {
    let handle = try patchHandle(payload: payload, expectedDigest: expectedDigest)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT reference.handle_id, document.total_bytes, document.is_truncated
        FROM bridge_pipeline_patch_references AS reference
        JOIN bridge_pipeline_patch_documents AS document
          ON document.handle_id = reference.handle_id
        WHERE reference.task_id = ? AND reference.generation = ?
        LIMIT 2
        """,
      arguments: [scope.taskID.rawValue, scope.generation]
    )
    guard rows.count <= 1 else { throw PipelineArtifactStoreError.corruptRecord }
    guard let handle else {
      guard rows.isEmpty else { throw PipelineArtifactStoreError.corruptRecord }
      return
    }
    if rows.isEmpty {
      try register(handle, scope: scope, in: db)
      return
    }
    guard let row = rows.first,
      row["handle_id"] == handle.rawValue,
      row["total_bytes"] == handle.totalBytes,
      row["is_truncated"] == handle.isTruncated
    else { throw PipelineArtifactStoreError.corruptRecord }
  }

  static func scope(taskID: String, generation: Int64, in db: Database) throws
    -> TaskEvidenceScope
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT task_id, generation, project_id, thread_id, turn_id, event_sequence
          FROM bridge_pipeline_scopes WHERE task_id = ? AND generation = ?
          """,
        arguments: [taskID, generation]
      )
    else { throw PipelineArtifactStoreError.corruptRecord }
    do {
      return try TaskEvidenceScope(
        taskID: TaskID(rawValue: row["task_id"]),
        projectID: ProjectID(rawValue: row["project_id"]),
        threadID: ThreadID(rawValue: row["thread_id"]),
        turnID: TurnID(rawValue: row["turn_id"]),
        generation: row["generation"],
        eventSequence: row["event_sequence"]
      )
    } catch {
      throw PipelineArtifactStoreError.corruptRecord
    }
  }

  private static func validateDocument(
    _ handle: GitPatchHandle,
    in db: Database,
    taskID: TaskID
  ) throws {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT total_bytes, is_truncated FROM bridge_pipeline_patch_documents
          WHERE handle_id = ?
          """,
        arguments: [handle.rawValue]
      ),
      row["total_bytes"] == handle.totalBytes,
      row["is_truncated"] == handle.isTruncated
    else { throw PipelineArtifactStoreError.patchReferenceConflict(taskID) }
  }

  private static func canonicalize(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }
}
