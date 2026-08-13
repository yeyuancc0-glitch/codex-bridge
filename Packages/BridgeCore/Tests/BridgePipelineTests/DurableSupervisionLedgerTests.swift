import BridgeDomain
import BridgeSupervisor
import Foundation
import GRDB
import XCTest

@testable import BridgePipeline

final class DurableSupervisionLedgerTests: XCTestCase {
  func testReopenPreservesMultiTriggerCheckpointDecisionReducerAndEvidence() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope()
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    let checkpoint = try makeCheckpoint(
      scope: scope,
      sequence: 7,
      triggers: [.planChanged, .firstFileModification, .commandFailed]
    )
    let storedCheckpoint = try await ledger.appendCheckpoint(
      scope: scope,
      checkpoint: checkpoint
    )
    let position = SupervisorReviewPosition(checkpointSequence: 7, attempt: 0)
    let review = try await ledger.appendReview(
      scope: scope,
      position: position,
      result: .decision(try steerDecision())
    )

    XCTAssertEqual(
      storedCheckpoint.checkpoint.triggers,
      [
        .planChanged, .firstFileModification, .commandFailed,
      ])
    XCTAssertEqual(review.state.taskSteerCount, 1)
    XCTAssertEqual(review.action?.kind, .steer)
    XCTAssertEqual(review.action?.state, .pending)

    let reopened = try DurableSupervisionLedger(path: location.database.path)
    let state = try await reopened.state(for: scope)
    XCTAssertEqual(state?.state, review.state)
    XCTAssertEqual(state?.stateDigest, review.stateDigest)
    let reopenedCheckpoints = try await reopened.checkpoints(for: scope)
    let reopenedReviews = try await reopened.reviews(for: scope)
    XCTAssertEqual(reopenedCheckpoints.map(\.checkpoint), [checkpoint])
    XCTAssertEqual(reopenedReviews, [review])
    let summary = try await reopened.evidenceSummary(for: scope)
    XCTAssertEqual(summary.checkpointCount, 1)
    XCTAssertEqual(summary.reviewCount, 1)
    XCTAssertEqual(summary.appliedSteerCount, 0)
    XCTAssertEqual(summary.latestDecision, .steer)
    XCTAssertEqual(summary.latestDecisionDigest?.count, 64)
  }

  func testAppendIsIdempotentAndConflictsOnDifferentPayload() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let scope = try makeScope()
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    let checkpoint = try makeCheckpoint(scope: scope, sequence: 1)
    let first = try await ledger.appendCheckpoint(scope: scope, checkpoint: checkpoint)
    let second = try await ledger.appendCheckpoint(scope: scope, checkpoint: checkpoint)
    XCTAssertEqual(first, second)

    let position = SupervisorReviewPosition(checkpointSequence: 1, attempt: 0)
    let review = try await ledger.appendReview(
      scope: scope,
      position: position,
      result: .decision(try continueDecision())
    )
    let repeatedReview = try await ledger.appendReview(
      scope: scope,
      position: position,
      result: .decision(try continueDecision())
    )
    XCTAssertEqual(repeatedReview, review)

    let changed = try makeCheckpoint(scope: scope, sequence: 1, triggers: [.manual])
    await assertThrowsErrorAsync(
      try await ledger.appendCheckpoint(scope: scope, checkpoint: changed)
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .checkpointConflict(sequence: 1)
      )
    }
    await assertThrowsErrorAsync(
      try await ledger.appendReview(
        scope: scope,
        position: position,
        result: .invalidJSON
      )
    ) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .reviewConflict(position))
    }
  }

  func testGenerationCannotMixAndReplacementRequiresTerminalOlderScope() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let first = try makeScope(generation: 1)
    let second = try makeScope(turnID: "turn-2", generation: 2)
    _ = try await ledger.begin(scope: first, configuration: configuration())

    await assertThrowsErrorAsync(
      try await ledger.begin(scope: second, configuration: configuration())
    ) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .scopeConflict(first.taskID))
    }
    _ = try await ledger.supersede(scope: first)
    _ = try await ledger.begin(scope: second, configuration: configuration())

    await assertThrowsErrorAsync(
      try await ledger.appendCheckpoint(
        scope: first,
        checkpoint: self.makeCheckpoint(scope: first, sequence: 1)
      )
    ) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .scopeConflict(first.taskID))
    }
    let oldState = try await ledger.state(for: first)
    let currentState = try await ledger.state(for: first.taskID)
    XCTAssertEqual(oldState?.status, .superseded)
    XCTAssertEqual(currentState?.scope, second)
  }

  func testAmbiguousActionSurvivesRestartAndIsNeverReturnedAsPending() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope()
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    _ = try await ledger.appendCheckpoint(
      scope: scope,
      checkpoint: makeCheckpoint(scope: scope, sequence: 1)
    )
    let review = try await ledger.appendReview(
      scope: scope,
      position: SupervisorReviewPosition(checkpointSequence: 1, attempt: 0),
      result: .decision(try steerDecision())
    )
    let action = try XCTUnwrap(review.action)
    let pending = try await ledger.pendingActions()
    let attempting = try await ledger.beginActionAttempt(id: action.id)
    XCTAssertEqual(pending.map(\.id), [action.id])
    XCTAssertEqual(attempting.state, .ambiguous)

    let reopened = try DurableSupervisionLedger(path: location.database.path)
    let reopenedPending = try await reopened.pendingActions()
    let reopenedAmbiguous = try await reopened.ambiguousActions()
    XCTAssertTrue(reopenedPending.isEmpty)
    XCTAssertEqual(reopenedAmbiguous.map(\.id), [action.id])
    await assertThrowsErrorAsync(
      try await reopened.beginActionAttempt(id: action.id)
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .invalidActionTransition(from: .ambiguous, to: .ambiguous)
      )
    }
    let applied = try await reopened.markActionApplied(id: action.id)
    let remainingAmbiguous = try await reopened.ambiguousActions()
    let appliedSummary = try await reopened.evidenceSummary(for: scope)
    XCTAssertEqual(applied.state, .applied)
    XCTAssertTrue(remainingAmbiguous.isEmpty)
    XCTAssertEqual(appliedSummary.appliedSteerCount, 1)
  }

  func testPendingActionBlocksCloseUntilSuperseded() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let scope = try makeScope()
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    _ = try await ledger.appendCheckpoint(
      scope: scope,
      checkpoint: makeCheckpoint(scope: scope, sequence: 1)
    )
    let review = try await ledger.appendReview(
      scope: scope,
      position: SupervisorReviewPosition(checkpointSequence: 1, attempt: 0),
      result: .decision(try steerDecision())
    )
    let action = try XCTUnwrap(review.action)

    await assertThrowsErrorAsync(try await ledger.close(scope: scope)) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .pendingActions)
    }
    let superseded = try await ledger.supersedeAction(id: action.id)
    let closed = try await ledger.close(scope: scope)
    XCTAssertEqual(superseded.state, .superseded)
    XCTAssertEqual(closed.status, .completed)
  }

  func testAppendOnlyTablesRejectMutationAndCorruptReducerFailsClosed() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope()
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    _ = try await ledger.appendCheckpoint(
      scope: scope,
      checkpoint: makeCheckpoint(scope: scope, sequence: 1)
    )
    _ = try await ledger.appendReview(
      scope: scope,
      position: SupervisorReviewPosition(checkpointSequence: 1, attempt: 0),
      result: .decision(try continueDecision())
    )

    let database = try DatabaseQueue(path: location.database.path)
    await assertThrowsErrorAsync(
      try await database.write { db in
        try db.execute(
          sql: "UPDATE bridge_supervision_checkpoints SET created_at = created_at + 1"
        )
      }
    ) { _ in }
    await assertThrowsErrorAsync(
      try await database.write { db in
        try db.execute(sql: "DELETE FROM bridge_supervision_decisions")
      }
    ) { _ in }
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE bridge_supervision_scopes
          SET reducer_state_sha256 = zeroblob(32)
          WHERE task_id = ? AND generation = ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation]
      )
    }
    XCTAssertThrowsError(try DurableSupervisionLedger(path: location.database.path)) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .corruptRecord)
    }
  }

  func testCheckpointCapacityAndQueryLimitsAreBounded() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let scope = try makeScope()
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    for sequence in 1...DurableSupervisionLedger.maximumCheckpointsPerActiveScope {
      _ = try await ledger.appendCheckpoint(
        scope: scope,
        checkpoint: makeCheckpoint(scope: scope, sequence: UInt64(sequence))
      )
    }
    await assertThrowsErrorAsync(
      try await ledger.appendCheckpoint(
        scope: scope,
        checkpoint: self.makeCheckpoint(
          scope: scope,
          sequence: UInt64(DurableSupervisionLedger.maximumCheckpointsPerActiveScope + 1)
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .limitExceeded(
          field: "bridge_supervision_checkpoints",
          maximum: DurableSupervisionLedger.maximumCheckpointsPerActiveScope
        )
      )
    }
    await assertThrowsErrorAsync(
      try await ledger.checkpoints(for: scope, limit: 501)
    ) { error in
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .invalidArgument("limit"))
    }
  }

  func testSeparateConnectionsConvergeOnOneReviewAndAction() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope()
    let first = try DurableSupervisionLedger(path: location.database.path)
    let second = try DurableSupervisionLedger(path: location.database.path)
    _ = try await first.begin(scope: scope, configuration: configuration())
    _ = try await first.appendCheckpoint(
      scope: scope,
      checkpoint: makeCheckpoint(scope: scope, sequence: 1)
    )
    let position = SupervisorReviewPosition(checkpointSequence: 1, attempt: 0)
    let decision = try steerDecision()

    async let left = first.appendReview(
      scope: scope,
      position: position,
      result: .decision(decision)
    )
    async let right = second.appendReview(
      scope: scope,
      position: position,
      result: .decision(decision)
    )
    let records = try await [left, right]
    XCTAssertEqual(records[0], records[1])
    let storedReviews = try await first.reviews(for: scope)
    let storedActions = try await second.pendingActions()
    XCTAssertEqual(storedReviews.count, 1)
    XCTAssertEqual(storedActions.count, 1)
  }

  func testFinalDecisionProducesBoundedReportEvidenceWithoutAction() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let scope = try makeScope()
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    _ = try await ledger.appendCheckpoint(
      scope: scope,
      checkpoint: makeCheckpoint(
        scope: scope,
        sequence: 9,
        triggers: [.completionClaimed],
        stage: .final
      )
    )
    let review = try await ledger.appendReview(
      scope: scope,
      position: SupervisorReviewPosition(checkpointSequence: 9, attempt: 0),
      result: .decision(try finalAcceptDecision())
    )
    let summary = try await ledger.evidenceSummary(for: scope)

    XCTAssertNil(review.action)
    XCTAssertEqual(summary.checkpointCount, 1)
    XCTAssertEqual(summary.reviewCount, 1)
    XCTAssertEqual(summary.latestDecision, .finalAccept)
    XCTAssertEqual(summary.latestDecisionDigest?.count, 64)
  }

  func testActiveScopeCapacityIsEnforcedBeforeRestart() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    for index in 0..<DurableSupervisionLedger.maximumActiveScopes {
      let scope = try makeScope(taskID: "task-\(index)")
      _ = try await ledger.begin(scope: scope, configuration: configuration())
    }
    let overflow = try makeScope(taskID: "task-overflow")
    await assertThrowsErrorAsync(
      try await ledger.begin(scope: overflow, configuration: self.configuration())
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .limitExceeded(
          field: "activeScopes",
          maximum: DurableSupervisionLedger.maximumActiveScopes
        )
      )
    }
  }

  func testGlobalRecoveryRecordBudgetSpansScopesAndSurvivesRestart() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let firstScope = try makeScope(taskID: "task-budget-a")
    let secondScope = try makeScope(taskID: "task-budget-b")
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: firstScope, configuration: configuration())
    _ = try await ledger.begin(scope: secondScope, configuration: configuration())

    let checkpointCount = (DurableSupervisionLedger.maximumActiveRecoveryRecords - 2) / 2
    for sequence in 1...checkpointCount {
      _ = try await ledger.appendCheckpoint(
        scope: firstScope,
        checkpoint: makeCheckpoint(scope: firstScope, sequence: UInt64(sequence))
      )
      _ = try await ledger.appendCheckpoint(
        scope: secondScope,
        checkpoint: makeCheckpoint(scope: secondScope, sequence: UInt64(sequence))
      )
    }

    let reopened = try DurableSupervisionLedger(path: location.database.path)
    let firstState = try await reopened.state(for: firstScope)
    let secondState = try await reopened.state(for: secondScope)
    XCTAssertEqual(firstState?.scope, firstScope)
    XCTAssertEqual(secondState?.scope, secondScope)
    await assertThrowsErrorAsync(
      try await reopened.appendCheckpoint(
        scope: firstScope,
        checkpoint: self.makeCheckpoint(
          scope: firstScope,
          sequence: UInt64(checkpointCount + 1)
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .limitExceeded(
          field: "activeRecoveryRecords",
          maximum: DurableSupervisionLedger.maximumActiveRecoveryRecords
        )
      )
    }
  }

  func testPayloadBudgetRejectsWriteAndOversizedRestartBeforeDecode() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope(taskID: "task-payload-budget")
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    let database = try DatabaseQueue(path: location.database.path)
    let insertionTimestamp = Date().timeIntervalSince1970
    let scopePayloadBytes = try await database.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT LENGTH(configuration_json) + LENGTH(reducer_state_json)
          FROM bridge_supervision_scopes WHERE task_id = ? AND generation = ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation]
      ) ?? 0
    }
    let fullRows = 127
    let checkpointMaximumBytes = SupervisorCheckpoint.maximumEncodedBytes
    let fillerBytes =
      DurableSupervisionLedger.maximumActiveRecoveryPayloadBytes - scopePayloadBytes
      - fullRows * checkpointMaximumBytes - 1
    XCTAssertGreaterThanOrEqual(fillerBytes, 2)
    try await database.write { db in
      try db.execute(
        sql: """
          WITH RECURSIVE numbers(value) AS (
            SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < ?
          )
          INSERT INTO bridge_supervision_checkpoints (
            task_id, generation, checkpoint_sequence, checkpoint_json,
            checkpoint_sha256, created_at
          )
          SELECT ?, ?, value, zeroblob(?), zeroblob(32), ? FROM numbers
          """,
        arguments: [
          fullRows, scope.taskID.rawValue, scope.generation, checkpointMaximumBytes,
          insertionTimestamp,
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_supervision_checkpoints (
            task_id, generation, checkpoint_sequence, checkpoint_json,
            checkpoint_sha256, created_at
          ) VALUES (?, ?, ?, zeroblob(?), zeroblob(32), ?)
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, fullRows + 1, fillerBytes,
          insertionTimestamp,
        ]
      )
    }

    let oversizedSequence = UInt64(fullRows + 2)
    let oversizedCheckpoint = try makeCheckpoint(scope: scope, sequence: oversizedSequence)
    await assertThrowsErrorAsync(
      try await ledger.appendCheckpoint(scope: scope, checkpoint: oversizedCheckpoint)
    ) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .limitExceeded(
          field: "activeRecoveryPayloadBytes",
          maximum: DurableSupervisionLedger.maximumActiveRecoveryPayloadBytes
        )
      )
    }
    let oversizedPayload = try DurableSupervisionLedger.canonicalJSON(oversizedCheckpoint)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_supervision_checkpoints (
            task_id, generation, checkpoint_sequence, checkpoint_json,
            checkpoint_sha256, created_at
          ) VALUES (?, ?, ?, ?, zeroblob(32), ?)
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, Int64(oversizedSequence), oversizedPayload,
          insertionTimestamp,
        ]
      )
    }
    XCTAssertThrowsError(try DurableSupervisionLedger(path: location.database.path)) { error in
      XCTAssertEqual(
        error as? DurableSupervisionLedgerError,
        .limitExceeded(
          field: "activeRecoveryPayloadBytes",
          maximum: DurableSupervisionLedger.maximumActiveRecoveryPayloadBytes
        )
      )
    }
  }

  private func makeScope(
    taskID: String = "task-supervision",
    turnID: String = "turn-1",
    generation: Int64 = 1
  ) throws -> DurableSupervisionScope {
    try DurableSupervisionScope(
      taskID: TaskID(rawValue: taskID),
      projectID: ProjectID(rawValue: "project-supervision"),
      threadID: ThreadID(rawValue: "thread-supervision"),
      turnID: TurnID(rawValue: turnID),
      generation: generation
    )
  }

  private func configuration() -> SupervisorGuardConfiguration {
    SupervisorGuardConfiguration(
      deterministicFallbackAuthorized: false,
      maximumSteersPerTurn: 3,
      maximumSteersPerTask: 5
    )
  }

  private func makeCheckpoint(
    scope: DurableSupervisionScope,
    sequence: UInt64,
    triggers: [SupervisorCheckpointTrigger] = [.planChanged],
    stage: SupervisorCheckpointStage = .progress
  ) throws -> SupervisorCheckpoint {
    try SupervisorCheckpoint(
      sequence: sequence,
      taskID: scope.taskID.rawValue,
      turnID: scope.turnID.rawValue,
      stage: stage,
      triggers: triggers,
      content: SupervisorCheckpointContent(
        taskContract: "Implement the durable supervision ledger.",
        executionModel: "gpt-5.6",
        executionEffort: "medium",
        recentEvents: ["A bounded execution event was observed."],
        remainingAutomaticSteers: 5
      )
    )
  }

  private func continueDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .continue,
      risk: .low,
      summary: "Execution remains within the task contract.",
      evidence: ["The checkpoint is bounded."],
      confidence: 0.95
    )
  }

  private func steerDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .steer,
      risk: .medium,
      summary: "A bounded correction is required.",
      evidence: ["The current plan omitted a required verification."],
      instruction: "Run the registered verification before completion.",
      confidence: 0.94,
      issueID: "verification.missing"
    )
  }

  private func finalAcceptDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .finalAccept,
      risk: .low,
      summary: "Final evidence satisfies the task contract.",
      evidence: ["The final checkpoint contains bounded evidence."],
      confidence: 0.98
    )
  }

  private func temporaryDatabase() throws -> (directory: URL, database: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-supervision-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return (directory, directory.appendingPathComponent("ledger.sqlite"))
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ verify: (any Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    verify(error)
  }
}
