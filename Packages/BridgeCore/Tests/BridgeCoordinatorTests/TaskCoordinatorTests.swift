import BridgeCoordinator
import BridgeDomain
import BridgePersistence
import Foundation
import XCTest

final class TaskCoordinatorTests: XCTestCase {
  func testIdempotentApprovedTaskRunsThroughCodexApprovalAndFinalReport() async throws {
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

    let approvalID = ApprovalID(rawValue: "approval-one")
    await runtime.emit(.codexApprovalRequested(approvalID), taskID: submitted.aggregate.id)
    try await waitForPhase(
      .awaitingCodexApproval,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )
    _ = try await coordinator.resolveCodexApproval(
      taskID: submitted.aggregate.id,
      approvalID: approvalID,
      approved: true
    )
    let approvalResponses = await runtime.approvalResponses()
    XCTAssertEqual(approvalResponses, [approvalID: true])

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
    XCTAssertEqual(completedLocks, [])
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
        approved: true
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

    _ = try await restarted.beginRecoveryReconciliation(taskID: submitted.aggregate.id)
    let suspended = try await restarted.resolveRecovery(
      taskID: submitted.aggregate.id,
      to: .suspended
    )
    XCTAssertEqual(suspended.aggregate.phase, .suspended)
    let suspendedLocks = try await store.lockKeysOwned(by: submitted.aggregate.id)
    XCTAssertEqual(suspendedLocks, [])
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
  private var starts = 0
  private var taskStarts: [TaskID: UInt64] = [:]
  private var interrupts = 0
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]
  private var responses: [ApprovalID: Bool] = [:]
  private var steers: [(binding: ExecutionBinding, prompt: String)] = []

  init(
    failApprovalResolution: Bool = false,
    failInterrupt: Bool = false,
    steerGate: SteerGate? = nil
  ) {
    self.failApprovalResolution = failApprovalResolution
    self.failInterrupt = failInterrupt
    self.steerGate = steerGate
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
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: previousBinding?.threadID ?? ThreadID(rawValue: "thread-\(taskID.rawValue)"),
        turnID: TurnID(rawValue: "turn-\(taskID.rawValue)-\(generation)"),
        turnGeneration: generation
      ),
      observations: stream
    )
  }

  func start(taskID: TaskID, submission: TaskSubmission) -> TaskExecutionSession {
    start(taskID: taskID, submission: submission, previousBinding: nil)
  }

  func resolveApproval(taskID _: TaskID, approvalID: ApprovalID, approved: Bool) throws {
    if failApprovalResolution { throw FakeRuntimeError.approvalResolutionFailed }
    responses[approvalID] = approved
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

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }

  func finish(taskID: TaskID) {
    continuations[taskID]?.finish()
  }

  func startCount() -> Int { starts }
  func interruptCount() -> Int { interrupts }
  func approvalResponses() -> [ApprovalID: Bool] { responses }
  func steerCalls() -> [(binding: ExecutionBinding, prompt: String)] { steers }
}

private enum FakeRuntimeError: Error {
  case approvalResolutionFailed
  case interruptFailed
  case steerFailed
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
