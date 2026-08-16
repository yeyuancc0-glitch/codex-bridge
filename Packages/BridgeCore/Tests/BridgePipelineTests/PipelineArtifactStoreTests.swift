import BridgeDomain
import BridgeGit
import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import BridgePipeline

final class PipelineArtifactStoreTests: XCTestCase {
  private struct Evidence: Codable, Equatable, Sendable {
    let dirty: Bool
    let root: String
    let values: [String: Int]
  }

  private struct LargeEvidence: Codable, Sendable {
    let value: String
  }

  func testArtifactsAndScopeSurviveRestartWithoutPayloadInSummary() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let evidence = Evidence(
      dirty: true,
      root: "/Volumes/private/repository",
      values: ["z": 2, "a": 1]
    )
    let storedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try PipelineArtifactStore(path: fixture.path)
    _ = try await first.begin(scope, at: storedAt)
    let initial = try await first.store(
      scope: scope,
      kind: .gitBaseline,
      payload: evidence,
      at: storedAt
    )
    _ = try await first.advance(scope, to: .baselineCaptured, at: storedAt)

    let reopened = try PipelineArtifactStore(path: fixture.path)
    let current = try await reopened.currentScope(for: scope.taskID)
    let finalization = try await reopened.finalization(for: scope.taskID)
    let summaries = try await reopened.artifacts(for: scope)
    let payload: Evidence? = try await reopened.trustedPayload(
      for: scope,
      kind: .gitBaseline
    )

    XCTAssertEqual(current, scope)
    XCTAssertEqual(finalization?.stage, .baselineCaptured)
    XCTAssertEqual(summaries, [initial])
    XCTAssertEqual(payload, evidence)
    XCTAssertFalse(String(describing: summaries).contains(evidence.root))
    XCTAssertEqual(initial.sha256.count, 64)
  }

  func testSameArtifactIsIdempotentAndDifferentPayloadConflicts() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try makeScope()
    let evidence = Evidence(dirty: false, root: "/private/root", values: ["a": 1])
    _ = try await store.begin(scope)

    let first = try await store.store(
      scope: scope,
      kind: .gitBaseline,
      schemaVersion: 2,
      payload: evidence,
      at: Date(timeIntervalSince1970: 10)
    )
    let repeated = try await store.store(
      scope: scope,
      kind: .gitBaseline,
      schemaVersion: 2,
      payload: evidence,
      at: Date(timeIntervalSince1970: 20)
    )
    XCTAssertEqual(repeated, first)

    do {
      _ = try await store.store(
        scope: scope,
        kind: .gitBaseline,
        schemaVersion: 2,
        payload: Evidence(dirty: true, root: evidence.root, values: evidence.values)
      )
      XCTFail("Expected immutable artifact conflict")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .artifactConflict(scope.taskID, .gitBaseline)
      )
    }
  }

  func testGenerationAndIdentityCannotBeMixed() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let first = try makeScope(generation: 1, turnID: "turn-one")
    _ = try await store.begin(first)
    _ = try await store.advance(first, to: .superseded)
    let second = try makeScope(generation: 2, turnID: "turn-two", eventSequence: 8)
    _ = try await store.begin(second)

    let forgedFirst = try makeScope(generation: 1, turnID: "turn-two")
    do {
      _ = try await store.store(
        scope: forgedFirst,
        kind: .gitBaseline,
        payload: Evidence(dirty: false, root: "/tmp", values: [:])
      )
      XCTFail("Expected scope identity conflict")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .scopeConflict(first.taskID))
    }

    do {
      _ = try await store.begin(try makeScope(generation: 1, turnID: "turn-three"))
      XCTFail("Expected generation rollback conflict")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .scopeConflict(first.taskID))
    }
    let current = try await store.currentScope(for: first.taskID)
    XCTAssertEqual(current, second)

    do {
      _ = try await store.store(
        scope: first,
        kind: .gitBaseline,
        payload: Evidence(dirty: false, root: "/tmp", values: [:])
      )
      XCTFail("Expected stale generation conflict")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .scopeConflict(first.taskID))
    }

    let thirdWithStaleSequence = try makeScope(
      generation: 3,
      turnID: "turn-three",
      eventSequence: 2
    )
    _ = try await store.advance(second, to: .superseded)
    do {
      _ = try await store.begin(thirdWithStaleSequence)
      XCTFail("Expected event sequence rollback conflict")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .scopeConflict(first.taskID))
    }
  }

  func testChecksumTamperingFailsClosedWhenDatabaseReopens() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(scope)
    _ = try await store.store(
      scope: scope,
      kind: .gitBaseline,
      payload: Evidence(dirty: false, root: "/private/root", values: [:])
    )
    let database = try DatabaseQueue(path: fixture.path)
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE bridge_pipeline_artifacts SET payload_json = ?
          WHERE task_id = ? AND generation = ? AND kind_category = 'git_baseline'
          """,
        arguments: [Data("{\"tampered\":true}".utf8), scope.taskID.rawValue, scope.generation]
      )
    }

    XCTAssertThrowsError(try PipelineArtifactStore(path: fixture.path)) { error in
      XCTAssertEqual(error as? PipelineArtifactStoreError, .corruptRecord)
    }
  }

  func testTerminalHistoryIsValidatedLazilyWhenAccessed() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(scope)
    _ = try await store.store(
      scope: scope,
      kind: .gitBaseline,
      payload: Evidence(dirty: false, root: "/private/root", values: [:])
    )
    _ = try await store.advance(scope, to: .failed)
    let database = try DatabaseQueue(path: fixture.path)
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE bridge_pipeline_artifacts SET payload_json = ?
          WHERE task_id = ? AND generation = ? AND kind_category = 'git_baseline'
          """,
        arguments: [Data("{\"tampered\":true}".utf8), scope.taskID.rawValue, scope.generation]
      )
    }

    let reopened = try PipelineArtifactStore(path: fixture.path)
    do {
      let _: Evidence? = try await reopened.trustedPayload(for: scope, kind: .gitBaseline)
      XCTFail("Expected terminal artifact corruption to fail on access")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .corruptRecord)
    }
  }

  func testStartupRejectsActivePayloadsBeyondAggregateBudgetBeforeDecoding() async throws {
    let fixture = try makeFixture()
    let first = try makeScope(taskID: "task-one")
    let second = try makeScope(taskID: "task-two")
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(first)
    _ = try await store.begin(second)
    let database = try DatabaseQueue(path: fixture.path)
    let payload = Data(
      ("{\"value\":\"" + String(repeating: "x", count: 524_276) + "\"}").utf8
    )
    let digest = Data(SHA256.hash(data: payload))
    try await database.write { db in
      for scope in [first, second] {
        for index in 1...33 {
          try db.execute(
            sql: """
              INSERT INTO bridge_pipeline_artifacts (
                task_id, generation, kind_category, kind_key, schema_version,
                payload_json, payload_sha256, created_at
              ) VALUES (?, ?, 'verification', ?, 1, ?, ?, 1)
              """,
            arguments: [
              scope.taskID.rawValue, scope.generation,
              String(format: "check-%02d", index), payload, digest,
            ]
          )
        }
      }
    }

    XCTAssertThrowsError(try PipelineArtifactStore(path: fixture.path)) { error in
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .limitExceeded(
          field: "activePayloadBytes",
          maximum: PipelineArtifactStore.maximumActivePayloadBytes
        )
      )
    }
  }

  func testStartupQueriesUsePendingStageAndArtifactPrimaryKeyIndexes() async throws {
    let fixture = try makeFixture()
    _ = try PipelineArtifactStore(path: fixture.path)
    let database = try DatabaseQueue(path: fixture.path)
    let plans = try await database.read { db -> ([String], [String]) in
      let scopeRows = try Row.fetchAll(
        db,
        sql: "EXPLAIN QUERY PLAN \(PipelineArtifactStore.activeScopeQuery)",
        arguments: [PipelineArtifactStore.maximumActiveScopes + 1]
      )
      let artifactRows = try Row.fetchAll(
        db,
        sql: "EXPLAIN QUERY PLAN \(PipelineArtifactStore.activeArtifactQuery)",
        arguments: ["task", 1, PipelineArtifactStore.maximumArtifactsPerActiveScope + 1]
      )
      return (
        scopeRows.map { $0["detail"] as String },
        artifactRows.map { $0["detail"] as String }
      )
    }
    XCTAssertFalse(plans.0.contains { $0.contains("SCAN s") }, plans.0.joined(separator: " | "))
    XCTAssertTrue(
      plans.0.contains { $0.contains("bridge_pipeline_pending_stage") },
      plans.0.joined(separator: " | ")
    )
    XCTAssertFalse(
      plans.1.contains { $0.contains("SCAN bridge_pipeline_artifacts") },
      plans.1.joined(separator: " | ")
    )
  }

  func testPatchReleaseHandleLookupUsesBoundedIndex() async throws {
    let fixture = try makeFixture()
    _ = try PipelineArtifactStore(path: fixture.path)
    let database = try DatabaseQueue(path: fixture.path)
    let details = try await database.read { db -> [String] in
      let indexes = try db.indexes(on: "bridge_pipeline_patch_release_items")
      XCTAssertTrue(
        indexes.contains {
          $0.name == "bridge_pipeline_patch_release_item_handle"
            && $0.columns == ["handle_id", "task_id"]
        }
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT EXISTS (
            SELECT 1 FROM bridge_pipeline_patch_release_items WHERE handle_id = ?
          )
          """,
        arguments: [
          "patch_\(String(repeating: "a", count: 32))_\(String(repeating: "b", count: 64))"
        ]
      )
      return rows.map { $0["detail"] as String }
    }
    XCTAssertTrue(
      details.contains { $0.contains("bridge_pipeline_patch_release_item_handle") },
      details.joined(separator: " | ")
    )
  }

  func testPayloadSizeLimitIsEnforcedBeforeWrite() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try makeScope()
    _ = try await store.begin(scope)
    let payload = LargeEvidence(
      value: String(repeating: "x", count: PipelineArtifactStore.maximumPayloadBytes)
    )

    do {
      _ = try await store.store(scope: scope, kind: .gitBaseline, payload: payload)
      XCTFail("Expected payload bound")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .limitExceeded(field: "payload", maximum: PipelineArtifactStore.maximumPayloadBytes)
      )
    }
    let artifacts = try await store.artifacts(for: scope)
    XCTAssertEqual(artifacts, [])
  }

  func testPendingFinalizationSagaRequiresDurableEvidenceAtEachBoundary() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try makeScope()
    let evidence = Evidence(dirty: false, root: "/private/root", values: [:])
    _ = try await store.begin(scope)
    _ = try await store.store(scope: scope, kind: .gitBaseline, payload: evidence)
    _ = try await store.advance(scope, to: .baselineCaptured)
    _ = try await store.advance(scope, to: .turnCompleted)
    let initialPending = try await store.pendingFinalizations()
    XCTAssertEqual(initialPending.map(\.scope), [scope])

    do {
      _ = try await store.advance(scope, to: .gitFinalCaptured)
      XCTFail("Expected final Git evidence prerequisite")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .missingPrerequisite(.gitFinal))
    }

    _ = try await store.store(scope: scope, kind: .gitFinal, payload: evidence)
    _ = try await store.advance(scope, to: .gitFinalCaptured)
    do {
      _ = try await store.advance(scope, to: .verificationCompleted)
      XCTFail("Expected verification evidence prerequisite")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .missingPrerequisite(.verification("required"))
      )
    }
    _ = try await store.store(
      scope: scope,
      kind: .verification("swift-test"),
      payload: evidence
    )
    _ = try await store.advance(scope, to: .verificationCompleted)
    _ = try await store.store(
      scope: scope,
      kind: .supervisorFinalDecision,
      payload: evidence
    )
    _ = try await store.advance(scope, to: .supervisorReviewed)
    _ = try await store.store(scope: scope, kind: .reportMetadata, payload: evidence)
    _ = try await store.advance(scope, to: .reportStored)
    _ = try await store.advance(scope, to: .completed)

    let finalPending = try await store.pendingFinalizations()
    let finalization = try await store.finalization(for: scope.taskID)
    XCTAssertTrue(finalPending.isEmpty)
    XCTAssertEqual(finalization?.stage, .completed)
  }

  func testRecoverableQueryCannotBeStarvedByEarlierPendingStages() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let evidence = Evidence(dirty: false, root: "/private/root", values: [:])
    for index in 0..<100 {
      let scope = try makeScope(taskID: "early-\(index)")
      _ = try await store.begin(scope)
      _ = try await store.store(scope: scope, kind: .gitBaseline, payload: evidence)
      _ = try await store.advance(scope, to: .baselineCaptured)
      _ = try await store.advance(scope, to: .turnCompleted)
    }

    let recoverable = try makeScope(taskID: "recoverable")
    _ = try await store.begin(recoverable)
    _ = try await store.store(scope: recoverable, kind: .gitBaseline, payload: evidence)
    _ = try await store.advance(recoverable, to: .baselineCaptured)
    _ = try await store.advance(recoverable, to: .turnCompleted)
    _ = try await store.store(scope: recoverable, kind: .gitFinal, payload: evidence)
    _ = try await store.advance(recoverable, to: .gitFinalCaptured)
    _ = try await store.store(
      scope: recoverable,
      kind: .verification("swift-test"),
      payload: evidence
    )
    _ = try await store.advance(recoverable, to: .verificationCompleted)
    _ = try await store.store(
      scope: recoverable,
      kind: .supervisorFinalDecision,
      payload: evidence
    )
    _ = try await store.advance(recoverable, to: .supervisorReviewed)
    _ = try await store.store(scope: recoverable, kind: .reportMetadata, payload: evidence)

    let mixedPage = try await store.pendingFinalizations(limit: 100)
    XCTAssertFalse(mixedPage.contains(where: { $0.scope == recoverable }))
    let targeted = try await store.recoverableFinalizations()
    XCTAssertEqual(targeted.map(\.scope), [recoverable])
  }

  func testInvalidTimestampsAndDecodedScopesAreRejected() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try makeScope()
    do {
      _ = try await store.begin(scope, at: Date(timeIntervalSince1970: .infinity))
      XCTFail("Expected non-finite timestamp rejection")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .invalidArgument("date"))
    }

    let validScope = try JSONEncoder().encode(scope)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: validScope) as? [String: Any]
    )
    object["generation"] = 0
    let invalidScope = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try JSONDecoder().decode(TaskEvidenceScope.self, from: invalidScope)) {
      error in
      XCTAssertEqual(error as? PipelineArtifactStoreError, .invalidArgument("generation"))
    }
  }

  func testSchemaIsAdditiveAndOrphanedCurrentScopeFailsClosed() async throws {
    let fixture = try makeFixture()
    let original = try DatabaseQueue(path: fixture.path)
    try await original.write { db in
      try db.execute(sql: "CREATE TABLE unrelated_data (value TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO unrelated_data (value) VALUES ('kept')")
    }
    let store = try PipelineArtifactStore(path: fixture.path)
    let scope = try makeScope()
    _ = try await store.begin(scope)
    let value = try await original.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM unrelated_data")
    }
    XCTAssertEqual(value, "kept")

    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let tamper = try DatabaseQueue(path: fixture.path, configuration: configuration)
    try await tamper.write { db in
      try db.execute(
        sql: "UPDATE bridge_pipeline_current_scopes SET generation = 99 WHERE task_id = ?",
        arguments: [scope.taskID.rawValue]
      )
    }
    let reopened = try PipelineArtifactStore(path: fixture.path)
    do {
      _ = try await reopened.currentScope(for: scope.taskID)
      XCTFail("Expected orphaned current scope to fail when accessed")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .corruptRecord)
    }
  }

  func testGitFinalPatchReferenceIsStoredAtomicallyAndSurvivesRestart() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let handle = makePatchHandle(byteCount: 27)
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(scope)
    _ = try await store.store(
      scope: scope,
      kind: .gitFinal,
      payload: makeGitFinal(patch: handle)
    )

    let database = try DatabaseQueue(path: fixture.path)
    let owner = try await database.read { db -> (String, Int, Bool)? in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
              SELECT reference.handle_id, document.total_bytes, document.is_truncated
              FROM bridge_pipeline_patch_references AS reference
              JOIN bridge_pipeline_patch_documents AS document
                ON document.handle_id = reference.handle_id
              WHERE reference.task_id = ? AND reference.generation = ?
            """,
          arguments: [scope.taskID.rawValue, scope.generation]
        )
      else { return nil }
      return (row["handle_id"], row["total_bytes"], row["is_truncated"])
    }
    XCTAssertEqual(owner?.0, handle.rawValue)
    XCTAssertEqual(owner?.1, handle.totalBytes)
    XCTAssertEqual(owner?.2, handle.isTruncated)

    let reopened = try PipelineArtifactStore(path: fixture.path)
    let evidence: GitFinalEvidence? = try await reopened.trustedPayload(
      for: scope,
      kind: .gitFinal
    )
    XCTAssertEqual(evidence?.patch, handle)
  }

  func testGitFinalArtifactRollsBackWhenPatchOwnershipCannotBeRegistered() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let handle = makePatchHandle(byteCount: 27)
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(scope)
    let database = try DatabaseQueue(path: fixture.path)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_pipeline_patch_documents (
            handle_id, total_bytes, is_truncated
          ) VALUES (?, ?, ?)
          """,
        arguments: [handle.rawValue, handle.totalBytes + 1, handle.isTruncated]
      )
    }

    do {
      _ = try await store.store(
        scope: scope,
        kind: .gitFinal,
        payload: makeGitFinal(patch: handle)
      )
      XCTFail("Expected patch metadata conflict")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .patchReferenceConflict(scope.taskID)
      )
    }
    let artifactCount = try await database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM bridge_pipeline_artifacts WHERE task_id = ?",
        arguments: [scope.taskID.rawValue]
      )
    }
    XCTAssertEqual(artifactCount, 0)
  }

  func testVersionOneGitPatchReferenceIsBackfilledOnlyOnBoundedTrustedAccess() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let handle = makePatchHandle(byteCount: 27)
    do {
      let store = try PipelineArtifactStore(path: fixture.path)
      _ = try await store.begin(scope)
      _ = try await store.store(
        scope: scope,
        kind: .gitFinal,
        payload: makeGitFinal(patch: handle)
      )
      _ = try await store.advance(scope, to: .failed)
    }
    try downgradePipelineSchemaToVersionOne(path: fixture.path)

    let reopened = try PipelineArtifactStore(path: fixture.path)
    let database = try DatabaseQueue(path: fixture.path)
    let beforeAccess = try await patchReferenceCount(taskID: scope.taskID, database: database)
    XCTAssertEqual(beforeAccess, 0)

    let evidence: GitFinalEvidence? = try await reopened.trustedPayload(
      for: scope,
      kind: .gitFinal
    )
    XCTAssertEqual(evidence?.patch, handle)
    let afterAccess = try await patchReferenceCount(taskID: scope.taskID, database: database)
    XCTAssertEqual(afterAccess, 1)
  }

  func testPruneRequiresOnlyTerminalScopesAndIsBounded() async throws {
    let fixture = try makeFixture()
    let store = try PipelineArtifactStore(path: fixture.path)
    let first = try makeScope(generation: 1, turnID: "turn-one", eventSequence: 3)
    _ = try await store.begin(first)
    do {
      _ = try await store.pruneTerminalScopes(for: first.taskID)
      XCTFail("Expected active scope retention to be rejected")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .retentionRequiresTerminalScopes(first.taskID)
      )
    }
    _ = try await store.advance(first, to: .failed)
    let second = try makeScope(generation: 2, turnID: "turn-two", eventSequence: 4)
    _ = try await store.begin(second)
    _ = try await store.advance(second, to: .failed)

    do {
      _ = try await store.pruneTerminalScopes(
        for: first.taskID,
        maximumScopeCount: 1
      )
      XCTFail("Expected retention scope bound")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .limitExceeded(field: "retentionScopes", maximum: 1)
      )
    }
    let current = try await store.currentScope(for: first.taskID)
    XCTAssertEqual(current, second)
  }

  func testTerminalPruneManifestIsDurableIdempotentAndBlocksHandleReuse() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let handle = makePatchHandle(byteCount: 27)
    let prunedAt = Date(timeIntervalSince1970: 1_800_000_000)
    do {
      let store = try PipelineArtifactStore(path: fixture.path)
      _ = try await store.begin(scope)
      _ = try await store.store(
        scope: scope,
        kind: .gitFinal,
        payload: makeGitFinal(patch: handle)
      )
      _ = try await store.advance(scope, to: .failed)
      let preparedManifest = try await store.pruneTerminalScopes(
        for: scope.taskID,
        at: prunedAt
      )
      let manifest = try XCTUnwrap(preparedManifest)
      XCTAssertEqual(manifest.patches, [handle])
      XCTAssertEqual(manifest.createdAt, prunedAt)
      XCTAssertEqual(manifest.sha256.count, 64)
      let current = try await store.currentScope(for: scope.taskID)
      let repeated = try await store.pruneTerminalScopes(
        for: scope.taskID,
        at: prunedAt.addingTimeInterval(1)
      )
      XCTAssertNil(current)
      XCTAssertEqual(repeated, manifest)
    }

    let reopened = try PipelineArtifactStore(path: fixture.path)
    let restartedManifest = try await reopened.patchReleaseManifest(for: scope.taskID)
    let manifest = try XCTUnwrap(restartedManifest)
    XCTAssertEqual(manifest.patches, [handle])
    let newOwner = try makeScope(taskID: "task-new")
    _ = try await reopened.begin(newOwner)
    do {
      _ = try await reopened.store(
        scope: newOwner,
        kind: .gitFinal,
        payload: makeGitFinal(patch: handle)
      )
      XCTFail("Expected pending physical release to block handle reuse")
    } catch {
      XCTAssertEqual(
        error as? PipelineArtifactStoreError,
        .patchReleasePending(handle.rawValue)
      )
    }
    let acknowledged = try await reopened.acknowledgePatchRelease(manifest)
    let repeatedAcknowledgement = try await reopened.acknowledgePatchRelease(manifest)
    let releasedManifest = try await reopened.patchReleaseManifest(for: scope.taskID)
    XCTAssertTrue(acknowledged)
    XCTAssertFalse(repeatedAcknowledgement)
    XCTAssertNil(releasedManifest)
  }

  func testSharedPatchIsReleasedOnlyAfterItsLastTaskReferenceIsPruned() async throws {
    let fixture = try makeFixture()
    let store = try PipelineArtifactStore(path: fixture.path)
    let shared = makePatchHandle(byteCount: 27)
    let first = try makeScope(taskID: "task-first")
    let second = try makeScope(taskID: "task-second")
    for scope in [first, second] {
      _ = try await store.begin(scope)
      _ = try await store.store(
        scope: scope,
        kind: .gitFinal,
        payload: makeGitFinal(patch: shared)
      )
      _ = try await store.advance(scope, to: .failed)
    }

    let preparedFirstManifest = try await store.pruneTerminalScopes(
      for: first.taskID,
      at: Date(timeIntervalSince1970: 100)
    )
    let firstManifest = try XCTUnwrap(preparedFirstManifest)
    XCTAssertTrue(firstManifest.patches.isEmpty)
    let database = try DatabaseQueue(path: fixture.path)
    let remainingReferences = try await patchReferenceCount(
      taskID: second.taskID,
      database: database
    )
    XCTAssertEqual(remainingReferences, 1)
    let documentCountAfterFirst = try await database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM bridge_pipeline_patch_documents WHERE handle_id = ?",
        arguments: [shared.rawValue]
      )
    }
    XCTAssertEqual(documentCountAfterFirst, 1)

    let preparedSecondManifest = try await store.pruneTerminalScopes(
      for: second.taskID,
      at: Date(timeIntervalSince1970: 101)
    )
    let secondManifest = try XCTUnwrap(preparedSecondManifest)
    XCTAssertEqual(secondManifest.patches, [shared])
    let firstAcknowledged = try await store.acknowledgePatchRelease(firstManifest)
    XCTAssertTrue(firstAcknowledged)
    let restarted = try PipelineArtifactStore(path: fixture.path)
    let durableSecondManifest = try await restarted.patchReleaseManifest(for: second.taskID)
    XCTAssertEqual(durableSecondManifest, secondManifest)
  }

  func testTerminalPatchReferenceMismatchFailsClosedOnAccess() async throws {
    let fixture = try makeFixture()
    let scope = try makeScope()
    let original = makePatchHandle(byteCount: 27)
    let forged = makePatchHandle(byteCount: 31, identifierByte: "c", digestByte: "d")
    let store = try PipelineArtifactStore(path: fixture.path)
    _ = try await store.begin(scope)
    _ = try await store.store(
      scope: scope,
      kind: .gitFinal,
      payload: makeGitFinal(patch: original)
    )
    _ = try await store.advance(scope, to: .failed)
    let database = try DatabaseQueue(path: fixture.path)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_pipeline_patch_documents (
            handle_id, total_bytes, is_truncated
          ) VALUES (?, ?, ?)
          """,
        arguments: [forged.rawValue, forged.totalBytes, forged.isTruncated]
      )
      try db.execute(
        sql: """
          UPDATE bridge_pipeline_patch_references SET handle_id = ?
          WHERE task_id = ? AND generation = ?
          """,
        arguments: [forged.rawValue, scope.taskID.rawValue, scope.generation]
      )
    }

    let reopened = try PipelineArtifactStore(path: fixture.path)
    do {
      let _: GitFinalEvidence? = try await reopened.trustedPayload(
        for: scope,
        kind: .gitFinal
      )
      XCTFail("Expected mismatched owner reference to fail closed")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .corruptRecord)
    }
  }

  private func makeScope(
    taskID: String = "task-one",
    generation: Int64 = 1,
    turnID: String = "turn-one",
    eventSequence: Int64 = 3
  ) throws -> TaskEvidenceScope {
    try TaskEvidenceScope(
      taskID: TaskID(rawValue: taskID),
      projectID: ProjectID(rawValue: "project-one"),
      threadID: ThreadID(rawValue: "thread-one"),
      turnID: TurnID(rawValue: turnID),
      generation: generation,
      eventSequence: eventSequence
    )
  }

  private func makeGitFinal(patch: GitPatchHandle?) -> GitFinalEvidence {
    GitFinalEvidence(
      projectIdentifier: "project-one",
      canonicalRootPath: "/tmp/project-one",
      capturedAt: Date(timeIntervalSince1970: 20),
      status: .notGitRepository,
      diffStat: "",
      changedFiles: [],
      untrackedFiles: [],
      patch: patch,
      changeAttribution: .unavailableForNonGitProject
    )
  }

  private func makePatchHandle(
    byteCount: Int,
    identifierByte: Character = "a",
    digestByte: Character = "b"
  ) -> GitPatchHandle {
    GitPatchHandle(
      rawValue:
        "patch_\(String(repeating: identifierByte, count: 32))_\(String(repeating: digestByte, count: 64))",
      totalBytes: byteCount,
      isTruncated: false
    )
  }

  private func patchReferenceCount(taskID: TaskID, database: DatabaseQueue) async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM bridge_pipeline_patch_references WHERE task_id = ?",
        arguments: [taskID.rawValue]
      ) ?? 0
    }
  }

  private func downgradePipelineSchemaToVersionOne(path: String) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let database = try DatabaseQueue(path: path, configuration: configuration)
    try database.write { db in
      try db.execute(sql: "DROP TABLE bridge_pipeline_patch_release_items")
      try db.execute(sql: "DROP TABLE bridge_pipeline_patch_release_manifests")
      try db.execute(sql: "DROP TABLE bridge_pipeline_patch_references")
      try db.execute(sql: "DROP TABLE bridge_pipeline_patch_documents")
      try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: [PipelineArtifactSchema.migrationV2]
      )
      try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: [PipelineArtifactSchema.migrationV3]
      )
      try db.execute(
        sql: "UPDATE bridge_pipeline_meta SET schema_version = 1 WHERE singleton = 1"
      )
    }
  }

  private func makeFixture() throws -> (path: String, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BridgePipelineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return (directory.appendingPathComponent("bridge.sqlite").path, directory)
  }
}
