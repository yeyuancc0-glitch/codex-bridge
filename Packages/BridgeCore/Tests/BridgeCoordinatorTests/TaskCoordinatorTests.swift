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

private actor FakeRuntime: TaskExecutionRuntime {
  private let failApprovalResolution: Bool
  private var starts = 0
  private var taskStarts: [TaskID: UInt64] = [:]
  private var interrupts = 0
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]
  private var responses: [ApprovalID: Bool] = [:]

  init(failApprovalResolution: Bool = false) {
    self.failApprovalResolution = failApprovalResolution
  }

  func lockKeys(for submission: TaskSubmission) -> [String] {
    ["thread:\(submission.idempotencyKey.rawValue)", "worktree:\(submission.projectID.rawValue)"]
  }

  func start(taskID: TaskID, submission _: TaskSubmission) -> TaskExecutionSession {
    starts += 1
    let generation = (taskStarts[taskID] ?? 0) + 1
    taskStarts[taskID] = generation
    var continuation: AsyncStream<TaskExecutionObservation>.Continuation!
    let stream = AsyncStream<TaskExecutionObservation> { continuation = $0 }
    continuations[taskID] = continuation
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: ThreadID(rawValue: "thread-\(taskID.rawValue)"),
        turnID: TurnID(rawValue: "turn-\(taskID.rawValue)-\(generation)"),
        turnGeneration: generation
      ),
      observations: stream
    )
  }

  func resolveApproval(taskID _: TaskID, approvalID: ApprovalID, approved: Bool) throws {
    if failApprovalResolution { throw FakeRuntimeError.approvalResolutionFailed }
    responses[approvalID] = approved
  }

  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) { interrupts += 1 }

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }

  func startCount() -> Int { starts }
  func interruptCount() -> Int { interrupts }
  func approvalResponses() -> [ApprovalID: Bool] { responses }
}

private enum FakeRuntimeError: Error {
  case approvalResolutionFailed
}
