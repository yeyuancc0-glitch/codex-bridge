import Foundation
import XCTest

@testable import BridgeDomain

final class TaskReducerTests: XCTestCase {
  func testHappyPathRequiresReportBeforeCompletion() throws {
    var task = makeTask()
    task = try apply(.preparationStarted, to: task)
    task = try apply(.turnStarted(binding()), to: task)
    task = try apply(.turnCompleted, to: task)

    XCTAssertEqual(task.phase, .verifying)
    XCTAssertThrowsError(try apply(.completionRecorded, to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .reportRequired)
    }

    task = try apply(.finalReportStored(reference: "report://task-1"), to: task)
    task = try apply(.completionRecorded, to: task)

    XCTAssertEqual(task.phase, .completed)
    XCTAssertThrowsError(try apply(.failureRecorded(reason: "late"), to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .terminalState(.completed))
    }
  }

  func testLocalApprovalHasApproveAndRejectPaths() throws {
    var approved = try apply(.localApprovalRequested, to: makeTask())
    XCTAssertEqual(approved.phase, .awaitingLocalApproval)

    approved = try apply(.localApprovalResolved(approved: true), to: approved)
    XCTAssertEqual(approved.phase, .preparing)

    var rejected = try apply(.localApprovalRequested, to: makeTask(id: "tsk-rejected"))
    rejected = try apply(.localApprovalResolved(approved: false), to: rejected)

    XCTAssertEqual(rejected.phase, .rejected)
    XCTAssertThrowsError(try apply(.preparationStarted, to: rejected)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .terminalState(.rejected))
    }
  }

  func testSupervisorActivityDoesNotChangeLifecyclePhase() throws {
    var task = try runningTask()

    task = try apply(.supervisionStarted, to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.activity, .supervising)

    task = try apply(.correctionStarted, to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.activity, .correcting)

    task = try apply(.supervisorActivityFinished, to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.activity, .idle)
  }

  func testSupervisorActivityRejectsOverlappingOrOutOfOrderEvents() throws {
    var task = try runningTask()

    XCTAssertThrowsError(try apply(.correctionStarted, to: task)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidTransition(phase: .running, event: "correctionStarted")
      )
    }

    task = try apply(.supervisionStarted, to: task)
    XCTAssertThrowsError(try apply(.supervisionStarted, to: task)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidTransition(phase: .running, event: "supervisionStarted")
      )
    }
  }

  func testAllCodexApprovalsMustResolveBeforeRunning() throws {
    let first = ApprovalID(rawValue: "apr-1")
    let second = ApprovalID(rawValue: "apr-2")
    var task = try runningTask()

    task = try apply(.codexApprovalRequested(first), to: task)
    task = try apply(.codexApprovalRequested(second), to: task)
    XCTAssertEqual(task.phase, .awaitingCodexApproval)
    XCTAssertEqual(task.pendingApprovalIDs, [first, second])

    task = try apply(.codexApprovalApproved(first), to: task)
    XCTAssertEqual(task.phase, .awaitingCodexApproval)
    XCTAssertEqual(task.pendingApprovalIDs, [second])

    task = try apply(.codexApprovalApproved(second), to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertTrue(task.pendingApprovalIDs.isEmpty)
  }

  func testDuplicateAndUnknownApprovalsAreRejected() throws {
    let approvalID = ApprovalID(rawValue: "apr-1")
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)

    XCTAssertThrowsError(try apply(.codexApprovalRequested(approvalID), to: task)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .approvalAlreadyPending(approvalID)
      )
    }

    let missing = ApprovalID(rawValue: "apr-missing")
    XCTAssertThrowsError(try apply(.codexApprovalApproved(missing), to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .approvalNotPending(missing))
    }
  }

  func testApprovalResolutionReservationIsExclusiveAndBlocksTurnCompletion() throws {
    let approvalID = ApprovalID(rawValue: "apr-resolving")
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)
    task = try apply(
      .codexApprovalResolutionRequested(approvalID, approved: true),
      to: task
    )

    XCTAssertTrue(task.pendingApprovalIDs.isEmpty)
    XCTAssertEqual(task.resolvingApprovalIDs, [approvalID])
    XCTAssertThrowsError(
      try apply(.codexApprovalResolutionRequested(approvalID, approved: false), to: task)
    ) { error in
      XCTAssertEqual(error as? TaskTransitionError, .approvalNotPending(approvalID))
    }
    XCTAssertThrowsError(try apply(.turnCompleted, to: task)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidTransition(phase: .awaitingCodexApproval, event: "turnCompleted")
      )
    }

    task = try apply(.codexApprovalApproved(approvalID), to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertTrue(task.resolvingApprovalIDs.isEmpty)
  }

  func testApprovalEvidenceIsBoundToActiveTurnAndRemovedWithResolution() throws {
    let approvalID = ApprovalID(rawValue: "apr-evidence")
    let evidence = try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .fileChange,
      authority: .correlatedFileChanges,
      threadID: ThreadID(rawValue: "thread-1"),
      turnID: TurnID(rawValue: "turn-1"),
      itemID: "item-file",
      startedAtMilliseconds: 12,
      operationTitle: "File change approval",
      changedPaths: ["Sources/App.swift"],
      evidenceDigest: String(repeating: "b", count: 64)
    )
    var task = try runningTask()
    task = try apply(.codexApprovalEvidenceRecorded(evidence), to: task)
    task = try apply(.codexApprovalRequested(approvalID), to: task)

    XCTAssertEqual(task.approvalEvidenceByID[approvalID], evidence)
    XCTAssertThrowsError(try apply(.turnCompleted, to: task))

    task = try apply(.codexApprovalApproved(approvalID), to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertTrue(task.approvalEvidenceByID.isEmpty)

    let wrongTurn = try CodexApprovalEvidence(
      approvalID: ApprovalID(rawValue: "apr-wrong-turn"),
      kind: .fileChange,
      authority: .correlatedFileChanges,
      threadID: ThreadID(rawValue: "thread-1"),
      turnID: TurnID(rawValue: "turn-other"),
      itemID: "item-file",
      startedAtMilliseconds: 12,
      operationTitle: "File change approval",
      evidenceDigest: String(repeating: "c", count: 64)
    )
    XCTAssertThrowsError(try apply(.codexApprovalEvidenceRecorded(wrongTurn), to: task))
  }

  func testApprovalEvidenceAggregateBudgetRejectsBeforeSnapshotCapacity() throws {
    let evidence = try (0..<3).map { index in
      let approvalID = ApprovalID(rawValue: "apr-large-\(index)")
      let entries = try (0..<CodexApprovalFileChangeManifest.maximumEntries).map { entryIndex in
        try CodexApprovalFileChangeManifestEntry(
          path: "Sources/\(index)-\(entryIndex)-\(String(repeating: "x", count: 800))",
          kind: .update,
          movePath: "Sources/Target-\(entryIndex).swift",
          diffByteCount: 1,
          diffSHA256: String(repeating: "a", count: 64)
        )
      }
      let manifest = try CodexApprovalFileChangeManifest(
        entries: entries,
        totalDiffBytes: entries.count,
        rootDevice: 1,
        rootInode: 2
      )
      return try CodexApprovalEvidence(
        approvalID: approvalID,
        kind: .fileChange,
        authority: .correlatedFileChanges,
        threadID: ThreadID(rawValue: "thread-1"),
        turnID: TurnID(rawValue: "turn-1"),
        itemID: "item-large-\(index)",
        startedAtMilliseconds: Int64(index),
        operationTitle: "File change approval",
        evidenceDigest: String(repeating: "b", count: 64),
        fileChangeManifest: manifest
      )
    }

    var task = try runningTask()
    for value in evidence.prefix(2) {
      task = try apply(.codexApprovalEvidenceRecorded(value), to: task)
      task = try apply(.codexApprovalRequested(value.approvalID), to: task)
    }
    XCTAssertLessThan(
      try JSONEncoder().encode(task.approvalEvidenceByID).count,
      TaskAggregate.maximumApprovalEvidenceEncodedBytes
    )
    XCTAssertThrowsError(try apply(.codexApprovalEvidenceRecorded(evidence[2]), to: task))

    task.approvalEvidenceByID[evidence[2].approvalID] = evidence[2]
    let oversized = try JSONEncoder().encode(task)
    XCTAssertThrowsError(try JSONDecoder().decode(TaskAggregate.self, from: oversized))
  }

  func testDeniedCodexApprovalRequestsStopButDoesNotClaimInterruption() throws {
    let approvalID = ApprovalID(rawValue: "apr-denied")
    let intent = StopIntent(
      operationID: OperationID(rawValue: "op-denied"),
      outcome: .interrupt,
      reason: "approval denied"
    )
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)
    task = try apply(.codexApprovalDenied(approvalID, intent), to: task)

    XCTAssertEqual(task.phase, .awaitingCodexApproval)
    XCTAssertEqual(task.stopIntent, intent)

    task = try apply(.turnStopped, to: task)
    XCTAssertEqual(task.phase, .interrupted)
  }

  func testInterruptIntentDoesNotBecomeInterruptedUntilTurnStops() throws {
    let intent = StopIntent(
      operationID: OperationID(rawValue: "op-interrupt"),
      outcome: .interrupt,
      reason: "user requested"
    )
    var task = try runningTask()

    task = try apply(.stopRequested(intent), to: task)
    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.stopIntent, intent)

    task = try apply(.turnStopped, to: task)
    XCTAssertEqual(task.phase, .interrupted)
    XCTAssertNil(task.stopIntent)
    XCTAssertThrowsError(try apply(.resumeRequested, to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .terminalState(.interrupted))
    }
  }

  func testSuspendCanResumeAsNextTurnGeneration() throws {
    let suspend = StopIntent(
      operationID: OperationID(rawValue: "op-suspend"),
      outcome: .suspend
    )
    var task = try runningTask()
    task = try apply(.stopRequested(suspend), to: task)
    task = try apply(.turnStopped, to: task)

    XCTAssertEqual(task.phase, .suspended)

    task = try apply(.resumeRequested, to: task)
    task = try apply(
      .turnStarted(binding(turn: "turn-2", generation: 2)),
      to: task
    )

    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.binding?.turnGeneration, 2)
  }

  func testTurnCompletionWinsOverPendingInterruptIntentAsObservedFact() throws {
    let interrupt = StopIntent(
      operationID: OperationID(rawValue: "op-too-late"),
      outcome: .interrupt
    )
    var task = try runningTask()
    task = try apply(.stopRequested(interrupt), to: task)
    task = try apply(.turnCompleted, to: task)

    XCTAssertEqual(task.phase, .verifying)
    XCTAssertNil(task.stopIntent)
  }

  func testRecoveryCanBecomeUnknownAndReconcileWithoutRestartingTurn() throws {
    var task = try runningTask()
    let originalBinding = task.binding

    task = try apply(.recoveryStarted, to: task)
    XCTAssertEqual(task.phase, .recovering)
    XCTAssertEqual(task.recoveryOrigin, .running)

    task = try apply(.recoveryAmbiguous, to: task)
    XCTAssertEqual(task.phase, .unknown)

    task = try apply(.recoveryStarted, to: task)
    task = try apply(.recoveryResolved(to: .running), to: task)

    XCTAssertEqual(task.phase, .running)
    XCTAssertEqual(task.binding, originalBinding)
    XCTAssertNil(task.recoveryOrigin)
  }

  func testRecoveryCannotClaimCompletedWithoutReport() throws {
    var task = try runningTask()
    task = try apply(.recoveryStarted, to: task)

    XCTAssertThrowsError(try apply(.recoveryResolved(to: .completed), to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .reportRequired)
    }
  }

  func testRecoveryPreservesAwaitingApprovalUntilEveryTicketResolves() throws {
    let approvalID = ApprovalID(rawValue: "apr-recovery")
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)
    task = try apply(.recoveryStarted, to: task)

    XCTAssertThrowsError(try apply(.recoveryResolved(to: .running), to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .invalidRecoveryTarget(.running))
    }

    task = try apply(.recoveryResolved(to: .awaitingCodexApproval), to: task)
    task = try apply(.codexApprovalApproved(approvalID), to: task)
    XCTAssertEqual(task.phase, .running)
  }

  func testRecoveryCannotRestoreAnAmbiguousResolvingApproval() throws {
    let approvalID = ApprovalID(rawValue: "apr-ambiguous")
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)
    task = try apply(
      .codexApprovalResolutionRequested(approvalID, approved: true),
      to: task
    )
    task = try apply(.recoveryStarted, to: task)

    XCTAssertThrowsError(try apply(.recoveryResolved(to: .awaitingCodexApproval), to: task)) {
      error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidRecoveryTarget(.awaitingCodexApproval)
      )
    }
  }

  func testFailureIsTerminal() throws {
    var task = try apply(.preparationStarted, to: makeTask())
    task = try apply(.failureRecorded(reason: "Codex process exited"), to: task)

    XCTAssertEqual(task.phase, .failed)
    XCTAssertEqual(task.failureReason, "Codex process exited")
    XCTAssertThrowsError(try apply(.recoveryStarted, to: task)) { error in
      XCTAssertEqual(error as? TaskTransitionError, .terminalState(.failed))
    }
  }

  func testIllegalTransitionsAndBindingChangesAreRejected() throws {
    let draft = makeTask()
    XCTAssertThrowsError(try apply(.turnStarted(binding()), to: draft)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidTransition(phase: .draft, event: "turnStarted")
      )
    }

    var task = try runningTask()
    let suspend = StopIntent(
      operationID: OperationID(rawValue: "op-suspend"),
      outcome: .suspend
    )
    task = try apply(.stopRequested(suspend), to: task)
    task = try apply(.turnStopped, to: task)
    task = try apply(.resumeRequested, to: task)

    XCTAssertThrowsError(
      try apply(
        .turnStarted(
          ExecutionBinding(
            threadID: ThreadID(rawValue: "thread-other"),
            turnID: TurnID(rawValue: "turn-2"),
            turnGeneration: 2
          )
        ),
        to: task
      )
    ) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidBinding(reason: "thread changed between turns")
      )
    }
  }

  func testInvalidSubmissionCannotLeaveDraft() {
    let invalid = makeTask(
      id: "tsk-invalid",
      goal: "  ",
      acceptanceCriteria: []
    )

    XCTAssertThrowsError(try apply(.preparationStarted, to: invalid)) { error in
      XCTAssertEqual(
        error as? TaskTransitionError,
        .invalidSubmission(field: "contract.goal")
      )
    }
    XCTAssertEqual(invalid.phase, .draft)
  }

  func testAggregateAndEventsRoundTripThroughCodable() throws {
    let approvalID = ApprovalID(rawValue: "apr-round-trip")
    var task = try runningTask()
    task = try apply(.codexApprovalRequested(approvalID), to: task)
    task = try apply(.supervisionStarted, to: task)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let taskData = try encoder.encode(task)
    let decodedTask = try JSONDecoder().decode(TaskAggregate.self, from: taskData)

    XCTAssertEqual(decodedTask, task)

    let event = TaskEvent.stopRequested(
      StopIntent(
        operationID: OperationID(rawValue: "op-round-trip"),
        outcome: .interrupt,
        reason: "operator"
      )
    )
    let eventData = try encoder.encode(event)
    let decodedEvent = try JSONDecoder().decode(TaskEvent.self, from: eventData)

    XCTAssertEqual(decodedEvent, event)

    let reservation = TaskEvent.codexApprovalResolutionRequested(
      approvalID,
      approved: true
    )
    let reservationData = try encoder.encode(reservation)
    let decodedReservation = try JSONDecoder().decode(TaskEvent.self, from: reservationData)
    XCTAssertEqual(decodedReservation, reservation)
  }

  func testLegacyAggregateWithoutResolvingApprovalsDecodesCompatibly() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(try runningTask())
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "resolvingApprovalIDs")
    object.removeValue(forKey: "approvalEvidenceByID")
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoded = try JSONDecoder().decode(TaskAggregate.self, from: legacyData)

    XCTAssertTrue(decoded.resolvingApprovalIDs.isEmpty)
    XCTAssertTrue(decoded.approvalEvidenceByID.isEmpty)
    XCTAssertEqual(decoded.phase, .running)
  }
}

extension TaskReducerTests {
  fileprivate func makeTask(
    id: String = "tsk-1",
    goal: String = "Implement the task state machine",
    acceptanceCriteria: [String] = ["All reducer tests pass"]
  ) -> TaskAggregate {
    TaskAggregate(
      id: TaskID(rawValue: id),
      submission: TaskSubmission(
        idempotencyKey: IdempotencyKey(rawValue: "conversation:message"),
        projectID: ProjectID(rawValue: "project-1"),
        thread: .new,
        execution: ExecutionOptions(
          model: "gpt-5.6-sol",
          effort: "high",
          permissionMode: "workspaceWrite",
          networkAccess: false
        ),
        supervisor: SupervisorOptions(
          enabled: true,
          model: "gpt-5.6-luna",
          effort: "medium"
        ),
        contract: TaskContract(
          goal: goal,
          acceptanceCriteria: acceptanceCriteria
        )
      )
    )
  }

  fileprivate func runningTask() throws -> TaskAggregate {
    var task = try apply(.preparationStarted, to: makeTask())
    task = try apply(.turnStarted(binding()), to: task)
    return task
  }

  fileprivate func binding(
    thread: String = "thread-1",
    turn: String = "turn-1",
    generation: UInt64 = 1
  ) -> ExecutionBinding {
    ExecutionBinding(
      threadID: ThreadID(rawValue: thread),
      turnID: TurnID(rawValue: turn),
      turnGeneration: generation
    )
  }

  fileprivate func apply(_ event: TaskEvent, to task: TaskAggregate) throws -> TaskAggregate {
    try TaskReducer.reduce(task, event: event)
  }
}
