import BridgeCoordinator
import BridgeDomain
import BridgePersistence
import Foundation
import XCTest

final class TaskCoordinatorTests: XCTestCase {
  func testDurableRuntimeRekeysThreadAndPersistsStartIntentBeforeTurnStart() async throws {
    let store = try EventStore.inMemory()
    let runtime = DurableFakeRuntime(store: store)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "durable-start", permissionMode: "read-only")
    )

    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let audit = await runtime.startAudit()
    XCTAssertEqual(audit?.locks, ["thread:thread-exact", "worktree:project"])
    XCTAssertEqual(audit?.runtimeIntentCount, 2)
    let binding = try await coordinator.task(submitted.aggregate.id).aggregate.binding
    XCTAssertEqual(binding?.threadID.rawValue, "thread-exact")
    XCTAssertEqual(binding?.turnGeneration, 1)
    let owned = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(owned, ["thread:thread-exact", "worktree:project"])
  }

  func testPipelinePreflightCompletesBeforeDurableTurnStarts() async throws {
    let store = try EventStore.inMemory()
    let order = PipelineLifecycleOrder()
    let runtime = DurableFakeRuntime(store: store, order: order)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime,
      pipeline: RecordingPipelineLifecycle(order: order)
    )

    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "pipeline-order", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)

    let events = await order.events()
    XCTAssertEqual(events, ["pipeline.preflight", "runtime.start", "pipeline.started"])
  }

  func testPipelinePreflightFailurePreventsDurableTurnStart() async throws {
    let store = try EventStore.inMemory()
    let runtime = DurableFakeRuntime(store: store)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime,
      pipeline: RecordingPipelineLifecycle(order: PipelineLifecycleOrder(), failPreflight: true)
    )

    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "pipeline-preflight-failure", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.failed, taskID: taskID, coordinator: coordinator)

    let audit = await runtime.startAudit()
    XCTAssertNil(audit)
    let ownedLocks = try await store.lockKeysOwned(by: taskID)
    XCTAssertTrue(ownedLocks.isEmpty)
  }

  func testSemanticExecutionFactPersistsBeforePipelineCallback() async throws {
    let store = try EventStore.inMemory()
    let order = PipelineLifecycleOrder()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime,
      pipeline: RecordingPipelineLifecycle(order: order)
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "semantic-fact", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let before = try await coordinator.task(taskID).lastSequence
    let observation = try TaskSemanticExecutionObservation(
      sourceID: "plan-source",
      evidence: .planChanged(
        try TaskPlanSnapshot(
          steps: [try TaskPlanStepSnapshot(text: "Implement", status: .inProgress)],
          explanation: nil
        )
      )
    )

    await runtime.emit(.semantic(observation), taskID: taskID)
    for _ in 0..<100 {
      if try await coordinator.task(taskID).lastSequence > before { break }
      try await Task.sleep(for: .milliseconds(5))
    }

    let projection = try await coordinator.task(taskID)
    XCTAssertEqual(projection.aggregate.phase, .running)
    XCTAssertEqual(projection.lastSequence, before + 1)
    let stored = try await store.events(for: taskID)
    XCTAssertEqual(stored.last?.kind, "task.semantic")
    let pipelineEvents = await order.events()
    XCTAssertEqual(pipelineEvents.last, "pipeline.semantic")
  }

  func testIdempotentLocallyApprovedTaskRunsThroughFinalReport() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.requireLocalApproval),
      runtime: runtime
    )
    let submission = makeSubmission(key: "same-request", permissionMode: "workspace-write")

    let submitted = try await coordinator.submit(origin: "chatgpt", submission: submission)
    let duplicate = try await coordinator.submit(origin: "chatgpt", submission: submission)
    XCTAssertEqual(submitted.aggregate.id, duplicate.aggregate.id)
    XCTAssertEqual(submitted.aggregate.phase, .awaitingLocalApproval)
    let startsBeforeApproval = await runtime.startCount()
    XCTAssertEqual(startsBeforeApproval, 0)

    _ = try await coordinator.resolveLocalApproval(taskID: submitted.aggregate.id, approved: true)
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let startsAfterApproval = await runtime.startCount()
    XCTAssertEqual(startsAfterApproval, 1)

    await runtime.emit(.turnCompleted, taskID: submitted.aggregate.id)
    try await waitForPhase(.verifying, taskID: submitted.aggregate.id, coordinator: coordinator)
    let completed = try await coordinator.complete(
      taskID: submitted.aggregate.id,
      reportReference: "report://task/final.json",
      authorization: .supervisorFinalAccept(decisionID: "decision-1")
    )
    XCTAssertEqual(completed.aggregate.phase, .completed)
    XCTAssertEqual(completed.aggregate.reportReference, "report://task/final.json")
    let completedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    let completedSnapshot = try await store.stateSnapshot(for: submitted.aggregate.id)
    XCTAssertEqual(completedLocks, [])
    XCTAssertEqual(completedSnapshot?.lastEventSequence, completed.lastSequence)
    XCTAssertEqual(completedSnapshot?.recoveryRequired, false)
  }

  func testCodexApprovalCannotBeAuthorized() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "approval-authorize-denied", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let approvalID = ApprovalID(rawValue: "approval-authorize-denied")
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)
    try await waitForPhase(.awaitingCodexApproval, taskID: taskID, coordinator: coordinator)

    do {
      _ = try await coordinator.resolveCodexApproval(
        taskID: taskID,
        approvalID: approvalID,
        approved: true
      )
      XCTFail("Expected Codex approval authorization to fail closed")
    } catch TaskCoordinatorError.codexApprovalAuthorizationUnavailable {}

    let projection = try await coordinator.task(taskID)
    XCTAssertTrue(projection.aggregate.pendingApprovalIDs.contains(approvalID))
    XCTAssertTrue(projection.aggregate.resolvingApprovalIDs.isEmpty)
    let responses = await runtime.approvalResponses()
    XCTAssertTrue(responses.isEmpty)
  }

  func testApprovalEvidenceAndPendingTicketCommitAtomically() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "approval-evidence", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let currentBinding = try await coordinator.task(taskID).aggregate.binding
    let binding = try XCTUnwrap(currentBinding)
    let approvalID = ApprovalID(rawValue: "approval-evidence")
    let evidence = try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .permissions,
      authority: .requestedPermissionProfile,
      threadID: binding.threadID,
      turnID: binding.turnID,
      itemID: "item-permissions",
      startedAtMilliseconds: 42,
      operationTitle: "Permission profile approval",
      displayArguments: ["write Sources/**"],
      workingDirectory: "/private/project",
      evidenceDigest: String(repeating: "d", count: 64)
    )
    await runtime.setApprovalEvidence(evidence, taskID: taskID)
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)
    try await waitForPhase(.awaitingCodexApproval, taskID: taskID, coordinator: coordinator)

    let projection = try await coordinator.task(taskID)
    XCTAssertEqual(projection.aggregate.approvalEvidenceByID[approvalID], evidence)
    let events = try await store.events(for: taskID)
    XCTAssertEqual(
      Array(events.suffix(2).map(\.kind)),
      [
        "task.codexApprovalEvidenceRecorded",
        "task.codexApprovalRequested",
      ])
    XCTAssertEqual(events[events.count - 2].createdAt, events.last?.createdAt)
  }

  func testExistingIdempotentTaskDoesNotReevaluateAdmissionPolicy() async throws {
    let admission = OneShotAdmission()
    let coordinator = TaskCoordinator(
      store: try EventStore.inMemory(),
      admission: admission,
      runtime: FakeRuntime()
    )
    let submission = makeSubmission(key: "stable-admission", permissionMode: "read-only")
    let first = try await coordinator.submit(origin: "chatgpt", submission: submission)
    let duplicate = try await coordinator.submit(origin: "chatgpt", submission: submission)

    XCTAssertEqual(duplicate.aggregate.id, first.aggregate.id)
    let calls = await admission.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testRejectedLocalApprovalNeverStartsRuntime() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.requireLocalApproval),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "mcp",
      submission: makeSubmission(key: "reject", permissionMode: "workspace-write")
    )

    let rejected = try await coordinator.resolveLocalApproval(
      taskID: submitted.aggregate.id,
      approved: false
    )
    XCTAssertEqual(rejected.aggregate.phase, .rejected)
    let starts = await runtime.startCount()
    let rejectedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(rejectedLocks, [])
  }

  func testApprovalRPCFailureKeepsIntentButNeverRecordsFalseApproval() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime(failApprovalResolution: true)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "approval-failure", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let approvalID = ApprovalID(rawValue: "approval-failure")
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: submitted.aggregate.id)
    try await waitForPhase(
      .awaitingCodexApproval,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )

    do {
      _ = try await coordinator.resolveCodexApproval(
        taskID: submitted.aggregate.id,
        approvalID: approvalID,
        approved: false
      )
      XCTFail("Expected runtime approval failure")
    } catch FakeRuntimeError.approvalResolutionFailed {}

    let projection = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(projection.aggregate.phase, .failed)
    let kinds = try await store.events(for: submitted.aggregate.id).map(\.kind)
    XCTAssertTrue(kinds.contains("task.runtimeIntent"))
    XCTAssertFalse(kinds.contains("task.codexApprovalApproved"))
    let ownedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertTrue(ownedLocks.isEmpty)
  }

  func testConcurrentApprovalResolutionIsDurablyReservedOnce() async throws {
    let gate = SteerGate(failsOnRelease: false)
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime(approvalGate: gate)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "approval-reservation", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let approvalID = ApprovalID(rawValue: "approval-reservation")
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)
    try await waitForPhase(.awaitingCodexApproval, taskID: taskID, coordinator: coordinator)
    let intentCountBefore = try await store.events(for: taskID).count {
      $0.kind == "task.runtimeIntent"
    }

    let first = Task {
      try await coordinator.resolveCodexApproval(
        taskID: taskID,
        approvalID: approvalID,
        approved: false
      )
    }
    await gate.waitUntilStarted()
    let reserved = try await coordinator.task(taskID)
    XCTAssertFalse(reserved.aggregate.pendingApprovalIDs.contains(approvalID))
    XCTAssertTrue(reserved.aggregate.resolvingApprovalIDs.contains(approvalID))

    do {
      _ = try await coordinator.resolveCodexApproval(
        taskID: taskID,
        approvalID: approvalID,
        approved: false
      )
      XCTFail("Expected the durable approval reservation to reject a second decision")
    } catch TaskTransitionError.approvalNotPending(let rejected) {
      XCTAssertEqual(rejected, approvalID)
    }

    await gate.release()
    let resolved = try await first.value
    XCTAssertEqual(resolved.aggregate.phase, .awaitingCodexApproval)
    XCTAssertTrue(resolved.aggregate.resolvingApprovalIDs.isEmpty)
    let responses = await runtime.approvalResponses()
    XCTAssertEqual(responses, [approvalID: false])
    let kinds = try await store.events(for: taskID).map(\.kind)
    XCTAssertEqual(kinds.filter { $0 == "task.runtimeIntent" }.count, intentCountBefore + 1)
    XCTAssertEqual(kinds.filter { $0 == "task.codexApprovalResolutionRequested" }.count, 1)
  }

  func testRecoveryFailsAmbiguousApprovalResolutionAndReleasesLocks() async throws {
    let gate = SteerGate(failsOnRelease: false)
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime(approvalGate: gate)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "approval-recovery", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let approvalID = ApprovalID(rawValue: "approval-recovery")
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)
    try await waitForPhase(.awaitingCodexApproval, taskID: taskID, coordinator: coordinator)
    let resolution = Task {
      try await coordinator.resolveCodexApproval(
        taskID: taskID,
        approvalID: approvalID,
        approved: false
      )
    }
    await gate.waitUntilStarted()

    let recoveringCoordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let recovered = try await recoveringCoordinator.recoverIncompleteTasks()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.failed])
    XCTAssertEqual(
      recovered.first?.aggregate.failureReason,
      "Approval resolution was ambiguous after restart."
    )
    let ownedLocks = try await store.lockKeysOwned(by: taskID)
    XCTAssertTrue(ownedLocks.isEmpty)

    await gate.release()
    do {
      _ = try await resolution.value
      XCTFail("Expected the stale approval resolution to fail")
    } catch {}
  }

  func testObservationStreamEndingWithoutTerminalEventFailsAndReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "ended-stream", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    await runtime.finish(taskID: submitted.aggregate.id)

    try await waitForPhase(.failed, taskID: submitted.aggregate.id, coordinator: coordinator)
    let ownedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertTrue(ownedLocks.isEmpty)
  }

  func testDuplicateApprovalAbortsExactSessionBeforeFailureReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "duplicate-approval", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let approvalID = ApprovalID(rawValue: "duplicate-approval")

    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)
    try await waitForPhase(.awaitingCodexApproval, taskID: taskID, coordinator: coordinator)
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: taskID)

    try await waitForPhase(.failed, taskID: taskID, coordinator: coordinator)
    let aborts = await runtime.abortCount()
    XCTAssertEqual(aborts, 1)
    let ownedLocks = try await store.lockKeysOwned(by: taskID)
    XCTAssertTrue(ownedLocks.isEmpty)
  }

  func testInterruptRPCFailureFailsTaskAndReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime(failInterrupt: true)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "interrupt-failure", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    do {
      _ = try await coordinator.interrupt(taskID: submitted.aggregate.id)
      XCTFail("Expected interrupt failure")
    } catch FakeRuntimeError.interruptFailed {}

    let failed = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(failed.aggregate.phase, .failed)
    let ownedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertTrue(ownedLocks.isEmpty)
  }

  func testInterruptIntentWaitsForObservedStopBeforeTerminalAndReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "interrupt", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let stopping = try await coordinator.interrupt(
      taskID: submitted.aggregate.id,
      reason: "User requested stop."
    )
    XCTAssertEqual(stopping.aggregate.phase, .running)
    XCTAssertNotNil(stopping.aggregate.stopIntent)
    let interrupts = await runtime.interruptCount()
    XCTAssertEqual(interrupts, 1)

    await runtime.emit(.turnStopped, taskID: submitted.aggregate.id)
    try await waitForPhase(.interrupted, taskID: submitted.aggregate.id, coordinator: coordinator)
    let interruptedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(interruptedLocks, [])
  }

  func testSteerPersistsIntentBeforeRuntimeAndUsesCurrentBinding() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "steer", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let projection = try await coordinator.steer(
      taskID: submitted.aggregate.id,
      prompt: "Keep the public API source-compatible."
    )
    XCTAssertEqual(projection.aggregate.phase, .running)
    let calls = await runtime.steerCalls()
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.prompt, "Keep the public API source-compatible.")
    XCTAssertEqual(calls.first?.binding, projection.aggregate.binding)
    let kinds = try await store.events(for: submitted.aggregate.id).map(\.kind)
    XCTAssertEqual(kinds.last, "task.runtimeIntent")
  }

  func testObservationAfterConcurrentSteerIntentRemainsAuthoritative() async throws {
    let store = try EventStore.inMemory()
    let gate = SteerGate(failsOnRelease: false)
    let runtime = FakeRuntime(steerGate: gate)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "steer-observation", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let running = try await coordinator.task(submitted.aggregate.id)
    let binding = try XCTUnwrap(running.aggregate.binding)
    let steer = Task {
      try await coordinator.steerWithResult(
        taskID: submitted.aggregate.id,
        expectedTurnID: binding.turnID,
        prompt: "Keep the current evidence boundary."
      )
    }
    await gate.waitUntilStarted()

    await runtime.emit(
      .codexApprovalRequested(ApprovalID(rawValue: "approval-concurrent")),
      taskID: submitted.aggregate.id
    )
    try await waitForPhase(
      .awaitingCodexApproval,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )
    await gate.release()
    _ = try await steer.value

    let projection = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(projection.aggregate.phase, .awaitingCodexApproval)
    XCTAssertEqual(
      projection.aggregate.pendingApprovalIDs,
      Set([ApprovalID(rawValue: "approval-concurrent")])
    )
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(locks.count, 2)
  }

  func testLateSteerFailureCannotFailOrUnlockResumedGeneration() async throws {
    let store = try EventStore.inMemory()
    let gate = SteerGate(failsOnRelease: true)
    let runtime = FakeRuntime(steerGate: gate)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "stale-steer-failure", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let firstRunning = try await coordinator.task(submitted.aggregate.id)
    let firstBinding = try XCTUnwrap(firstRunning.aggregate.binding)
    let steer = Task {
      try await coordinator.steerWithResult(
        taskID: submitted.aggregate.id,
        expectedTurnID: firstBinding.turnID,
        prompt: "This steer belongs only to generation one."
      )
    }
    await gate.waitUntilStarted()

    _ = try await coordinator.suspend(taskID: submitted.aggregate.id)
    await runtime.emit(.turnStopped, taskID: submitted.aggregate.id)
    try await waitForPhase(.suspended, taskID: submitted.aggregate.id, coordinator: coordinator)
    _ = try await coordinator.resume(taskID: submitted.aggregate.id)
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let resumedBeforeFailure = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(resumedBeforeFailure.aggregate.binding?.turnGeneration, 2)

    await gate.release()
    do {
      _ = try await steer.value
      XCTFail("Expected the delayed Runtime steer to fail")
    } catch FakeRuntimeError.steerFailed {}

    let resumedAfterFailure = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(resumedAfterFailure.aggregate.phase, .running)
    XCTAssertEqual(resumedAfterFailure.aggregate.binding, resumedBeforeFailure.aggregate.binding)
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(locks.count, 2)
  }

  func testSuspendedTaskReleasesLocksAndResumeStartsANewTurnGeneration() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "suspend-resume", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let firstProjection = try await coordinator.task(submitted.aggregate.id)
    let firstBinding = try XCTUnwrap(firstProjection.aggregate.binding)

    let stopping = try await coordinator.suspend(taskID: submitted.aggregate.id)
    XCTAssertEqual(stopping.aggregate.stopIntent?.outcome, .suspend)
    await runtime.emit(.turnStopped, taskID: submitted.aggregate.id)
    try await waitForPhase(.suspended, taskID: submitted.aggregate.id, coordinator: coordinator)
    let suspendedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(suspendedLocks, [])

    let preparing = try await coordinator.resume(taskID: submitted.aggregate.id)
    XCTAssertEqual(preparing.aggregate.phase, .preparing)
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let resumed = try await coordinator.task(submitted.aggregate.id)
    let resumedBinding = try XCTUnwrap(resumed.aggregate.binding)
    XCTAssertEqual(resumedBinding.threadID, firstBinding.threadID)
    XCTAssertNotEqual(resumedBinding.turnID, firstBinding.turnID)
    XCTAssertEqual(resumedBinding.turnGeneration, 2)
    let resumedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(resumedLocks.count, 2)

    do {
      _ = try await coordinator.steerWithResult(
        taskID: submitted.aggregate.id,
        expectedTurnID: firstBinding.turnID,
        prompt: "This instruction was authorized only for the prior turn."
      )
      XCTFail("Expected a stale expected turn to be rejected")
    } catch {
      XCTAssertEqual(error as? TaskCoordinatorTurnMismatchError, .init())
    }
    let staleSteers = await runtime.steerCalls()
    XCTAssertTrue(staleSteers.isEmpty)
  }

  func testResumeAtFirstVisibleSuspendedStateQueuesNextGeneration() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "immediate-resume", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    _ = try await coordinator.suspend(taskID: submitted.aggregate.id)
    let resume = Task<TaskProjection?, Never> {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while ContinuousClock.now < deadline {
        let phase = try? await coordinator.task(submitted.aggregate.id).aggregate.phase
        if phase == .suspended,
          let projection = try? await coordinator.resume(taskID: submitted.aggregate.id)
        {
          return projection
        }
        await Task.yield()
      }
      return nil
    }

    await runtime.emit(.turnStopped, taskID: submitted.aggregate.id)

    let preparing = await resume.value
    XCTAssertEqual(preparing?.aggregate.phase, .preparing)
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let resumed = try await coordinator.task(submitted.aggregate.id)
    XCTAssertEqual(resumed.aggregate.binding?.turnGeneration, 2)
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(locks.count, 2)
    let starts = await runtime.startCount()
    XCTAssertEqual(starts, 2)
  }

  func testRecoveryMarksAmbiguousActiveTaskUnknownWithoutReleasingLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let recovered = try await restarted.recoverIncompleteTasks()
    XCTAssertEqual(recovered.map(\.aggregate.phase), [.unknown])
    let recoveredLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(recoveredLocks.count, 2)

    let suspended = try await restarted.suspendAmbiguousRecovery(
      taskID: submitted.aggregate.id
    )
    XCTAssertEqual(suspended.aggregate.phase, .suspended)
    let suspendedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(suspendedLocks, [])

    let replayed = try await restarted.suspendAmbiguousRecovery(
      taskID: submitted.aggregate.id
    )
    XCTAssertEqual(replayed.lastSequence, suspended.lastSequence)
    XCTAssertEqual(replayed.aggregate.phase, .suspended)
  }

  func testRecoveryMovesExactCompletedTurnToVerifyingWithoutStartingAnotherTurn() async throws {
    let store = try EventStore.inMemory()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover-completed", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let recoveringRuntime = FakeRuntime(reconciliationStatus: .completed)
    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: recoveringRuntime
    )
    let recovered = try await restarted.recoverIncompleteTasks()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.verifying])
    let startCount = await recoveringRuntime.startCount()
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(startCount, 0)
    XCTAssertEqual(locks.count, 2)
  }

  func testRecoveryFailsExactFailedTurnAndReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover-failed", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)

    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime(reconciliationStatus: .failed)
    )
    let recovered = try await restarted.recoverIncompleteTasks()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.failed])
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertTrue(locks.isEmpty)
  }

  func testRecoveryUsesPersistedSuspendIntentForExactInterruptedTurn() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover-interrupted", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    _ = try await coordinator.suspend(taskID: submitted.aggregate.id)

    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime(reconciliationStatus: .interrupted)
    )
    let recovered = try await restarted.recoverIncompleteTasks()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.suspended])
    let locks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertTrue(locks.isEmpty)
  }

  func testLaterRecoveryCanResolvePreviouslyUnknownCompletedTurn() async throws {
    let store = try EventStore.inMemory()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover-later", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let ambiguous = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    _ = try await ambiguous.recoverIncompleteTasks()
    let unknown = try await ambiguous.task(submitted.aggregate.id)
    XCTAssertEqual(unknown.aggregate.phase, .unknown)

    let completed = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime(reconciliationStatus: .completed)
    )
    let recovered = try await completed.recoverIncompleteTasks()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.verifying])
    let verifying = try await completed.task(submitted.aggregate.id)
    XCTAssertEqual(verifying.aggregate.phase, .verifying)
  }

  func testRecoveryCannotOverwriteAConcurrentTaskMutation() async throws {
    let store = try EventStore.inMemory()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let submitted = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "recover-cas", permissionMode: "read-only")
    )
    try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
    let running = try await coordinator.task(submitted.aggregate.id)
    let binding = try XCTUnwrap(running.aggregate.binding)
    let gate = SteerGate(failsOnRelease: false)
    let recoveringRuntime = FakeRuntime(
      reconciliationGate: gate,
      reconciliationStatus: .completed
    )
    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: recoveringRuntime
    )
    let recovery = Task {
      try await restarted.recoverIncompleteTasks()
    }
    await gate.waitUntilStarted()

    _ = try await restarted.steerWithResult(
      taskID: submitted.aggregate.id,
      expectedTurnID: binding.turnID,
      prompt: "Keep the persisted intent authoritative."
    )
    await gate.release()

    do {
      _ = try await recovery.value
      XCTFail("Expected recovery CAS conflict")
    } catch EventStoreError.optimisticConcurrencyConflict {}
    let projection = try await restarted.task(submitted.aggregate.id)
    XCTAssertEqual(projection.aggregate.phase, .running)
    XCTAssertEqual(projection.lastSequence, running.lastSequence + 1)
  }

  func testWakeRootInvalidationAbortsBeforeFailureReleasesLocks() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime(reconciliationStatus: .invalidated)
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "wake-invalidated", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)

    _ = try await coordinator.reconcileActiveTasksAfterWake()
    try await waitForPhase(.failed, taskID: taskID, coordinator: coordinator)

    let abortCount = await runtime.abortCount()
    let locks = try await store.lockKeysOwned(by: taskID)
    XCTAssertEqual(abortCount, 1)
    XCTAssertTrue(locks.isEmpty)
  }

  func testWakeCannotKeepRunningWithoutAnAttachedObservationSession() async throws {
    let store = try EventStore.inMemory()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "wake-observed-only", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime(reconciliationStatus: .observedRunning)
    )

    let reconciled = try await restarted.reconcileActiveTasksAfterWake()

    XCTAssertEqual(reconciled.map(\.aggregate.phase), [.unknown])
    let locks = try await store.lockKeysOwned(by: taskID)
    XCTAssertEqual(locks.count, 2)
  }

  func testRecoveryReleasesLegacyLocksForSuspendedTask() async throws {
    let store = try EventStore.inMemory()
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let taskID = try await coordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "legacy-suspended-locks", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: coordinator)
    _ = try await coordinator.suspend(taskID: taskID)
    await runtime.emit(.turnStopped, taskID: taskID)
    try await waitForPhase(.suspended, taskID: taskID, coordinator: coordinator)
    try await store.acquireLocks(
      ["legacy:thread", "legacy:worktree"],
      ownerTaskID: taskID
    )

    let restarted = TaskCoordinator(
      store: store,
      admission: FixedAdmission(.start),
      runtime: FakeRuntime()
    )
    let recovered = try await restarted.recoverIncompleteTasks()

    XCTAssertTrue(recovered.isEmpty)
    let remainingLocks = try await store.lockKeysOwned(by: taskID)
    let restored = try await restarted.task(taskID)
    XCTAssertTrue(remainingLocks.isEmpty)
    XCTAssertEqual(restored.aggregate.phase, .suspended)
  }

  func testMismatchedIdempotentPayloadAndInvalidFinalAuthorizationFailClosed() async throws {
    let runtime = FakeRuntime()
    let coordinator = TaskCoordinator(
      store: try EventStore.inMemory(),
      admission: FixedAdmission(.start),
      runtime: runtime
    )
    let first = makeSubmission(key: "collision", permissionMode: "read-only")
    _ = try await coordinator.submit(origin: "chatgpt", submission: first)
    let second = TaskSubmission(
      idempotencyKey: first.idempotencyKey,
      projectID: first.projectID,
      thread: first.thread,
      execution: first.execution,
      supervisor: first.supervisor,
      contract: TaskContract(goal: "Different", acceptanceCriteria: ["Different"])
    )
    do {
      _ = try await coordinator.submit(origin: "chatgpt", submission: second)
      XCTFail("Expected mismatched idempotency fingerprint")
    } catch let error as EventStoreError {
      guard case .idempotencyMismatch = error else { return XCTFail("Unexpected \(error)") }
    }

    let finalRuntime = FakeRuntime()
    let finalCoordinator = TaskCoordinator(
      store: try EventStore.inMemory(),
      admission: FixedAdmission(.start),
      runtime: finalRuntime
    )
    let taskID = try await finalCoordinator.submit(
      origin: "chatgpt",
      submission: makeSubmission(key: "invalid-final", permissionMode: "read-only")
    ).aggregate.id
    try await waitForPhase(.running, taskID: taskID, coordinator: finalCoordinator)
    await finalRuntime.emit(.turnCompleted, taskID: taskID)
    try await waitForPhase(.verifying, taskID: taskID, coordinator: finalCoordinator)
    let before = try await finalCoordinator.task(taskID)
    do {
      _ = try await finalCoordinator.complete(
        taskID: taskID,
        reportReference: "report://task/final.json",
        authorization: .userOverride(reason: " ")
      )
      XCTFail("Expected invalid finalization authorization")
    } catch TaskCoordinatorError.invalidFinalizationAuthorization {
      let after = try await finalCoordinator.task(taskID)
      XCTAssertEqual(after, before)
    }
  }

  func testProjectRemovalGateBlocksNewTaskBeforeAdmissionOrPersistence() async throws {
    let store = try EventStore.inMemory()
    let admission = OneShotAdmission()
    let gate = TaskProjectMutationGate()
    let coordinator = TaskCoordinator(
      store: store,
      admission: admission,
      runtime: FakeRuntime(),
      projectMutationGate: gate
    )
    let projectID = ProjectID(rawValue: "project-one")
    let removal = try await gate.acquireRemoval(for: projectID)
    let submission = makeSubmission(key: "project-removal-gate", permissionMode: "read-only")

    do {
      _ = try await coordinator.submit(origin: "chatgpt", submission: submission)
      XCTFail("Expected project removal to reject a new task")
    } catch {
      XCTAssertEqual(
        error as? TaskProjectMutationGateError,
        .removalInProgress(projectID)
      )
    }
    let callsWhileRemoving = await admission.callCount()
    XCTAssertEqual(callsWhileRemoving, 0)

    await gate.releaseRemoval(removal)
    _ = try await coordinator.submit(origin: "chatgpt", submission: submission)
    let callsAfterRemoval = await admission.callCount()
    XCTAssertEqual(callsAfterRemoval, 1)
  }

  private func makeSubmission(key: String, permissionMode: String) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: key),
      projectID: ProjectID(rawValue: "project-one"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-test",
        effort: "medium",
        permissionMode: permissionMode,
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "gpt-luna", effort: "medium"),
      contract: TaskContract(goal: "Implement feature", acceptanceCriteria: ["Tests pass"])
    )
  }

  private func waitForPhase(
    _ expected: TaskPhase,
    taskID: TaskID,
    coordinator: TaskCoordinator
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if try await coordinator.task(taskID).aggregate.phase == expected { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Task did not reach \(expected)")
  }
}

private struct FixedAdmission: TaskAdmissionPolicy {
  let value: TaskAdmissionDecision

  init(_ value: TaskAdmissionDecision) { self.value = value }
  func decision(for _: TaskSubmission) -> TaskAdmissionDecision { value }
}

private actor OneShotAdmission: TaskAdmissionPolicy {
  private var calls = 0

  func decision(for _: TaskSubmission) throws -> TaskAdmissionDecision {
    calls += 1
    guard calls == 1 else { throw OneShotAdmissionError.calledAgain }
    return .start
  }

  func callCount() -> Int { calls }
}

private enum OneShotAdmissionError: Error {
  case calledAgain
}

private actor FakeRuntime: TaskExecutionRuntime {
  private let failApprovalResolution: Bool
  private let failInterrupt: Bool
  private let steerGate: SteerGate?
  private let approvalGate: SteerGate?
  private let reconciliationGate: SteerGate?
  private let reconciliationStatus: TaskExecutionReconciliationStatus?
  private var starts = 0
  private var taskStarts: [TaskID: UInt64] = [:]
  private var interrupts = 0
  private var aborts = 0
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]
  private var bindings: [TaskID: ExecutionBinding] = [:]
  private var responses: [ApprovalID: Bool] = [:]
  private var approvalEvidenceByTask: [TaskID: CodexApprovalEvidence] = [:]
  private var steers: [(binding: ExecutionBinding, prompt: String)] = []

  init(
    failApprovalResolution: Bool = false,
    failInterrupt: Bool = false,
    steerGate: SteerGate? = nil,
    approvalGate: SteerGate? = nil,
    reconciliationGate: SteerGate? = nil,
    reconciliationStatus: TaskExecutionReconciliationStatus? = nil
  ) {
    self.failApprovalResolution = failApprovalResolution
    self.failInterrupt = failInterrupt
    self.steerGate = steerGate
    self.approvalGate = approvalGate
    self.reconciliationGate = reconciliationGate
    self.reconciliationStatus = reconciliationStatus
  }

  func lockKeys(
    for submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> [String] {
    let threadKey =
      previousBinding?.threadID.rawValue ?? "new:\(submission.idempotencyKey.rawValue)"
    return ["thread:\(threadKey)", "worktree:\(submission.projectID.rawValue)"]
  }

  func lockKeys(for submission: TaskSubmission) -> [String] {
    lockKeys(for: submission, previousBinding: nil)
  }

  func start(
    taskID: TaskID,
    submission _: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> TaskExecutionSession {
    starts += 1
    let generation = max(taskStarts[taskID] ?? 0, previousBinding?.turnGeneration ?? 0) + 1
    taskStarts[taskID] = generation
    var continuation: AsyncStream<TaskExecutionObservation>.Continuation!
    let stream = AsyncStream<TaskExecutionObservation> { continuation = $0 }
    continuations[taskID] = continuation
    let binding = ExecutionBinding(
      threadID: previousBinding?.threadID ?? ThreadID(rawValue: "thread-\(taskID.rawValue)"),
      turnID: TurnID(rawValue: "turn-\(taskID.rawValue)-\(generation)"),
      turnGeneration: generation
    )
    bindings[taskID] = binding
    return TaskExecutionSession(
      binding: binding,
      observations: stream
    )
  }

  func start(taskID: TaskID, submission: TaskSubmission) -> TaskExecutionSession {
    start(taskID: taskID, submission: submission, previousBinding: nil)
  }

  func resolveApproval(
    taskID _: TaskID,
    approvalID: ApprovalID,
    approved: Bool
  ) async throws {
    if failApprovalResolution { throw FakeRuntimeError.approvalResolutionFailed }
    if let approvalGate { _ = await approvalGate.block() }
    responses[approvalID] = approved
  }

  func approvalEvidence(
    taskID: TaskID,
    approvalID: ApprovalID
  ) -> CodexApprovalEvidence? {
    guard approvalEvidenceByTask[taskID]?.approvalID == approvalID else { return nil }
    return approvalEvidenceByTask[taskID]
  }

  func finalizeApprovalResolution(
    taskID _: TaskID,
    approvalID _: ApprovalID,
    committed _: Bool
  ) {}

  func steer(taskID _: TaskID, binding: ExecutionBinding, prompt: String) async throws {
    steers.append((binding, prompt))
    if let steerGate, await steerGate.block() { throw FakeRuntimeError.steerFailed }
  }

  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) throws {
    if failInterrupt { throw FakeRuntimeError.interruptFailed }
    interrupts += 1
  }

  func abortSession(taskID: TaskID, binding: ExecutionBinding) throws {
    guard let current = bindings[taskID] else { return }
    guard current == binding else { throw FakeRuntimeError.bindingMismatch }
    aborts += 1
    bindings[taskID] = nil
    continuations.removeValue(forKey: taskID)?.finish()
  }

  func reconcile(
    taskID _: TaskID,
    submission _: TaskSubmission,
    binding: ExecutionBinding
  ) async -> TaskExecutionReconciliationResult {
    if let reconciliationGate { _ = await reconciliationGate.block() }
    guard let reconciliationStatus else { return .ambiguous }
    return .observed(binding: binding, status: reconciliationStatus)
  }

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }

  func setApprovalEvidence(_ evidence: CodexApprovalEvidence, taskID: TaskID) {
    approvalEvidenceByTask[taskID] = evidence
  }

  func finish(taskID: TaskID) {
    continuations[taskID]?.finish()
  }

  func startCount() -> Int { starts }
  func interruptCount() -> Int { interrupts }
  func abortCount() -> Int { aborts }
  func approvalResponses() -> [ApprovalID: Bool] { responses }
  func steerCalls() -> [(binding: ExecutionBinding, prompt: String)] { steers }
}

private enum FakeRuntimeError: Error {
  case approvalResolutionFailed
  case interruptFailed
  case steerFailed
  case bindingMismatch
}

private enum PipelineLifecycleTestError: Error {
  case preflightFailed
}

private actor PipelineLifecycleOrder {
  private var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }

  func events() -> [String] {
    values
  }
}

private struct RecordingPipelineLifecycle: TaskPipelineLifecycle {
  let order: PipelineLifecycleOrder
  var failPreflight = false

  func prepareForTurnStart(_: TaskPipelinePreStartContext) async throws {
    await order.append("pipeline.preflight")
    if failPreflight { throw PipelineLifecycleTestError.preflightFailed }
  }

  func recordStartedTurn(_: TaskPipelineStartedContext) async {
    await order.append("pipeline.started")
  }

  func recordSemanticObservation(_: TaskPipelineSemanticContext) async {
    await order.append("pipeline.semantic")
  }
}

private actor DurableFakeRuntime: DurableTaskExecutionRuntime {
  struct Audit: Sendable {
    let locks: [String]
    let runtimeIntentCount: Int
  }

  private let store: EventStore
  private let order: PipelineLifecycleOrder?
  private var audit: Audit?

  init(store: EventStore, order: PipelineLifecycleOrder? = nil) {
    self.store = store
    self.order = order
  }

  func lockKeys(
    for _: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> [String] {
    let thread = previousBinding?.threadID.rawValue ?? "provisional"
    return ["thread:\(thread)", "worktree:project"]
  }

  func lockKeys(for submission: TaskSubmission) -> [String] {
    lockKeys(for: submission, previousBinding: nil)
  }

  func prepare(
    taskID _: TaskID,
    submission _: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> PreparedTaskExecution {
    PreparedTaskExecution(
      threadID: previousBinding?.threadID ?? ThreadID(rawValue: "thread-exact"),
      turnGeneration: (previousBinding?.turnGeneration ?? 0) + 1,
      lockKeys: ["thread:thread-exact", "worktree:project"]
    )
  }

  func startPrepared(
    taskID: TaskID,
    submission _: TaskSubmission,
    preparation: PreparedTaskExecution
  ) async throws -> TaskExecutionSession {
    await order?.append("runtime.start")
    let locks = try await store.lockKeysOwned(by: taskID)
    let runtimeIntentCount = try await store.events(for: taskID).count(where: {
      $0.kind == "task.runtimeIntent"
    })
    audit = Audit(locks: locks, runtimeIntentCount: runtimeIntentCount)
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: preparation.threadID,
        turnID: TurnID(rawValue: "turn-exact"),
        turnGeneration: preparation.turnGeneration
      ),
      observations: AsyncStream { _ in }
    )
  }

  func cancelPreparation(taskID _: TaskID) {}

  func start(taskID: TaskID, submission: TaskSubmission) async throws -> TaskExecutionSession {
    try await start(
      taskID: taskID,
      submission: submission,
      previousBinding: nil
    )
  }

  func start(
    taskID: TaskID,
    submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) async throws -> TaskExecutionSession {
    let preparation = prepare(
      taskID: taskID,
      submission: submission,
      previousBinding: previousBinding
    )
    return try await startPrepared(
      taskID: taskID,
      submission: submission,
      preparation: preparation
    )
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) {}
  func steer(taskID _: TaskID, binding _: ExecutionBinding, prompt _: String) {}
  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) {}
  func startAudit() -> Audit? { audit }
}

private actor SteerGate {
  private let failsOnRelease: Bool
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(failsOnRelease: Bool) {
    self.failsOnRelease = failsOnRelease
  }

  func block() async -> Bool {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()
    await withCheckedContinuation { releaseContinuation = $0 }
    return failsOnRelease
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
