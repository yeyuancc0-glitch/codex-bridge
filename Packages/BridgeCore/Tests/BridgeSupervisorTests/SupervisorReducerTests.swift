import XCTest

@testable import BridgeSupervisor

final class SupervisorReducerTests: XCTestCase {
  func testPerTurnSteerLimitAllowsThreeAndRoutesFourthToHuman() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    for sequence in 1...3 {
      XCTAssertEqual(
        reducer.apply(try steerOutcome(sequence: UInt64(sequence), issueID: "issue-\(sequence)")),
        .steer("Correct issue \(sequence).")
      )
    }

    XCTAssertEqual(
      reducer.apply(try steerOutcome(sequence: 4, issueID: "issue-4")),
      .requireHumanReview(.turnSteerLimitReached("turn-1"))
    )
    XCTAssertEqual(reducer.state.steersByTurn["turn-1"], 3)
    XCTAssertEqual(reducer.state.taskSteerCount, 3)
    XCTAssertEqual(reducer.state.semanticStatus, .pausedForHuman)
  }

  func testPerTaskSteerLimitAllowsFiveAcrossTurns() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    let turns = ["a", "a", "a", "b", "b"]
    for (offset, turnID) in turns.enumerated() {
      let sequence = UInt64(offset + 1)
      XCTAssertEqual(
        reducer.apply(
          try steerOutcome(
            sequence: sequence,
            turnID: turnID,
            issueID: "issue-\(sequence)"
          )
        ),
        .steer("Correct issue \(sequence).")
      )
    }

    XCTAssertEqual(
      reducer.apply(try steerOutcome(sequence: 6, turnID: "c", issueID: "issue-6")),
      .requireHumanReview(.taskSteerLimitReached)
    )
    XCTAssertEqual(reducer.state.taskSteerCount, 5)
  }

  func testRepeatedSemanticIssueRoutesSecondOccurrenceToHumanWithoutSecondSteer() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    XCTAssertEqual(
      reducer.apply(try steerOutcome(sequence: 1, issueID: "scope.escape")),
      .steer("Correct issue 1.")
    )
    XCTAssertEqual(
      reducer.apply(try steerOutcome(sequence: 2, issueID: "scope.escape")),
      .requireHumanReview(.repeatedIssue("scope.escape"))
    )
    XCTAssertEqual(reducer.state.taskSteerCount, 1)
  }

  func testTwoInvalidJSONOutputsDisableSemanticSupervisionAndPauseByDefault() {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(1, attempt: 1))),
      .retrySemanticReview
    )
    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(1, attempt: 2))),
      .requestSuspend(.semanticSupervisionUnavailable)
    )
    XCTAssertEqual(reducer.state.semanticStatus, .pausedForHuman)
    XCTAssertEqual(reducer.state.consecutiveInvalidJSONCount, 2)
  }

  func testAuthorizedInvalidJSONDegradationNeverProducesAcceptance() {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: true)
    )
    _ = reducer.apply(.invalidJSON(position: position(1, attempt: 1)))

    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(1, attempt: 2))),
      .continueDeterministically(.invalidJSONLimitReached)
    )
    XCTAssertEqual(reducer.state.semanticStatus, .deterministicFallback)
    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(2, attempt: 1))),
      .semanticSupervisionUnavailable
    )
  }

  func testValidDecisionResetsInvalidJSONStreak() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(1, attempt: 1))),
      .retrySemanticReview
    )
    let checkpoint = try makeCheckpoint(sequence: 1)
    let decision = try makeDecision(.continue)
    XCTAssertEqual(
      reducer.apply(
        .decision(
          position: position(1, attempt: 2),
          checkpoint: checkpoint,
          decision: decision
        )
      ),
      .continueExecution
    )
    XCTAssertEqual(
      reducer.apply(.invalidJSON(position: position(2, attempt: 1))),
      .retrySemanticReview
    )
  }

  func testModelFailureUsesExplicitUserFallbackPolicy() {
    var strict = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    XCTAssertEqual(
      strict.apply(
        .modelFailure(position: position(1), failure: .rateLimited)
      ),
      .requestSuspend(.semanticSupervisionUnavailable)
    )

    var fallback = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: true)
    )
    XCTAssertEqual(
      fallback.apply(
        .modelFailure(position: position(1), failure: .processExited)
      ),
      .continueDeterministically(.modelFailure(.processExited))
    )
    XCTAssertNotEqual(
      fallback.state.semanticStatus,
      .active
    )
  }

  func testOutOfOrderOutcomeDoesNotMutateBudgets() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    let checkpoint = try makeCheckpoint(sequence: 2)
    XCTAssertEqual(
      reducer.apply(
        .decision(
          position: position(2),
          checkpoint: checkpoint,
          decision: try makeDecision(.continue)
        )
      ),
      .continueExecution
    )

    XCTAssertEqual(
      reducer.apply(try steerOutcome(sequence: 1, issueID: "late.issue")),
      .ignoredOutOfOrder
    )
    XCTAssertEqual(reducer.state.taskSteerCount, 0)
    XCTAssertEqual(reducer.state.lastReviewPosition, position(2))
  }

  func testReducerAlsoEnforcesFinalCheckpointGate() throws {
    var reducer = SupervisorReducer(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    let checkpoint = try makeCheckpoint(sequence: 1)
    XCTAssertEqual(
      reducer.apply(
        .decision(
          position: position(1),
          checkpoint: checkpoint,
          decision: try makeDecision(.finalAccept)
        )
      ),
      .rejectedInvalidReview
    )
    XCTAssertNil(reducer.state.lastReviewPosition)
    XCTAssertEqual(
      reducer.apply(
        .decision(
          position: position(1),
          checkpoint: checkpoint,
          decision: try makeDecision(.continue)
        )
      ),
      .continueExecution
    )
    XCTAssertEqual(reducer.state.lastReviewPosition, position(1))
  }

  func testActorSerializesReducerState() async throws {
    let guardActor = SupervisorGuard(
      configuration: SupervisorGuardConfiguration(deterministicFallbackAuthorized: false)
    )
    let action = await guardActor.apply(
      try steerOutcome(sequence: 1, issueID: "actor.issue")
    )
    let snapshot = await guardActor.snapshot()

    XCTAssertEqual(action, .steer("Correct issue 1."))
    XCTAssertEqual(snapshot.taskSteerCount, 1)
  }
}

private func position(_ sequence: UInt64, attempt: UInt16 = 1) -> SupervisorReviewPosition {
  SupervisorReviewPosition(checkpointSequence: sequence, attempt: attempt)
}

private func steerOutcome(
  sequence: UInt64,
  turnID: String = "turn-1",
  issueID: String
) throws -> SupervisorReviewOutcome {
  .decision(
    position: position(sequence),
    checkpoint: try makeCheckpoint(sequence: sequence, turnID: turnID),
    decision: try makeDecision(
      .steer,
      summary: "Issue \(sequence) requires a bounded correction.",
      instruction: "Correct issue \(sequence).",
      issueID: issueID
    )
  )
}
