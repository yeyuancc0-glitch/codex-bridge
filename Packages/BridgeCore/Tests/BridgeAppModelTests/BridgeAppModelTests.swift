import BridgePresentation
import XCTest

@testable import BridgeAppModel

@MainActor
final class BridgeAppModelTests: XCTestCase {
  func testStateStreamDrivesPresentationAndIgnoresStaleRevision() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()

    await backend.emit(snapshot(revision: 2, connection: .ready, taskTitle: "新状态"))
    let reachedNewState = await waitUntil {
      model.lifecycleState == .running(revision: 2, connection: .ready)
    }
    XCTAssertTrue(reachedNewState)
    XCTAssertEqual(firstTaskTitle(model.presentationStore.snapshot), "新状态")

    await backend.emit(snapshot(revision: 1, connection: .failed, taskTitle: "过期状态"))
    await Task.yield()

    XCTAssertEqual(model.lifecycleState, .running(revision: 2, connection: .ready))
    XCTAssertEqual(firstTaskTitle(model.presentationStore.snapshot), "新状态")
    await model.stop()
  }

  func testUnexpectedStreamEndFailsClosedAndClearsApprovalSheet() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()
    await backend.emit(approvalSnapshot(capabilities: [capability()]))
    let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
    XCTAssertTrue(presentedApproval)

    await backend.finish()

    let failed = await waitUntil { model.lifecycleState == .failed }
    XCTAssertTrue(failed)
    XCTAssertNil(model.presentationStore.presentedSheet)
    guard case .failed(let error) = model.presentationStore.snapshot.approvals else {
      return XCTFail("Expected approval projection to fail closed")
    }
    XCTAssertEqual(error.title, "状态同步已中断")
  }

  func testStopCancelsLifecycleAndRejectsLaterUpdates() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()
    await backend.emit(snapshot(revision: 1, connection: .ready, taskTitle: "已连接"))
    let connected = await waitUntil {
      model.lifecycleState == .running(revision: 1, connection: .ready)
    }
    XCTAssertTrue(connected)

    await model.stop()
    await backend.emit(snapshot(revision: 2, connection: .failed, taskTitle: "不应出现"))
    await Task.yield()

    XCTAssertEqual(model.lifecycleState, .stopped)
    XCTAssertEqual(firstTaskTitle(model.presentationStore.snapshot), "已连接")
  }

  func testApprovalWithoutCapabilityIsProjectedAsDenyOnly() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()
    await backend.emit(approvalSnapshot(capabilities: []))
    let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
    XCTAssertTrue(presentedApproval)

    guard case .codexApproval(let approval) = model.presentationStore.presentedSheet else {
      return XCTFail("Expected approval sheet")
    }
    XCTAssertFalse(approval.canAllow)

    await model.presentationStore.decideApproval(.allowOnce)
    let resolutions = await backend.resolutions()
    XCTAssertTrue(resolutions.isEmpty)
    XCTAssertNotNil(model.presentationStore.presentedSheet)
    await model.stop()
  }

  func testMismatchedThreadCapabilityCannotAuthorizeApproval() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    let valid = capability()
    let mismatch = BridgeApprovalCapability(
      approvalID: valid.approvalID,
      taskID: valid.taskID,
      threadID: "different-thread",
      turnID: valid.turnID,
      operationID: valid.operationID,
      authorizationHandle: valid.authorizationHandle,
      allowOnceEligible: true
    )
    model.start()
    await backend.emit(approvalSnapshot(capabilities: [mismatch]))
    let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
    XCTAssertTrue(presentedApproval)

    guard case .codexApproval(let approval) = model.presentationStore.presentedSheet else {
      return XCTFail("Expected approval sheet")
    }
    XCTAssertFalse(approval.canAllow)
    let bypassed = await model.presentationStore.perform(
      .decideApproval(approvalID: approval.id, decision: .allowOnce)
    )
    XCTAssertFalse(bypassed)
    let resolutions = await backend.resolutions()
    XCTAssertTrue(resolutions.isEmpty)
    await model.stop()
  }

  func testMismatchedTaskOrOperationCapabilityCannotAuthorizeApproval() async {
    let mismatches = [
      BridgeApprovalCapability(
        approvalID: "approval-1",
        taskID: "different-task",
        threadID: "thread-1",
        turnID: "turn-1",
        operationID: "operation-1",
        authorizationHandle: "opaque-one-time-handle",
        allowOnceEligible: true
      ),
      BridgeApprovalCapability(
        approvalID: "approval-1",
        taskID: "task-1",
        threadID: "thread-1",
        turnID: "turn-1",
        operationID: "different-operation",
        authorizationHandle: "opaque-one-time-handle",
        allowOnceEligible: true
      ),
    ]

    for mismatch in mismatches {
      let backend = TestBackend()
      let model = BridgeAppModel(backend: backend)
      model.start()
      await backend.emit(approvalSnapshot(capabilities: [mismatch]))
      let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
      XCTAssertTrue(presentedApproval)

      guard case .codexApproval(let approval) = model.presentationStore.presentedSheet else {
        return XCTFail("Expected approval sheet")
      }
      XCTAssertFalse(approval.canAllow)
      await model.stop()
    }
  }

  func testEligibleApprovalForwardsExactBackendCapability() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    let authorization = capability()
    model.start()
    await backend.emit(approvalSnapshot(capabilities: [authorization]))
    let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
    XCTAssertTrue(presentedApproval)

    await model.presentationStore.decideApproval(.allowOnce)

    let values = await backend.resolutions()
    XCTAssertEqual(
      values,
      [
        BridgeApprovalResolution(
          approvalID: authorization.approvalID,
          taskID: authorization.taskID,
          threadID: authorization.threadID,
          turnID: authorization.turnID,
          decision: .allowOnce,
          capability: authorization
        )
      ]
    )
    XCTAssertNil(model.presentationStore.presentedSheet)
    await model.stop()
  }

  func testDenyRemainsAvailableWithoutAllowCapability() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()
    await backend.emit(approvalSnapshot(capabilities: []))
    let presentedApproval = await waitUntil { model.presentationStore.presentedSheet != nil }
    XCTAssertTrue(presentedApproval)

    await model.presentationStore.decideApproval(.deny)

    let resolutions = await backend.resolutions()
    XCTAssertEqual(
      resolutions,
      [
        BridgeApprovalResolution(
          approvalID: "approval-1",
          taskID: "task-1",
          threadID: "thread-1",
          turnID: "turn-1",
          decision: .deny,
          capability: nil
        )
      ]
    )
    await model.stop()
  }

  func testDuplicateApprovalCapabilitiesInvalidateWholeStreamState() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    model.start()
    await backend.emit(approvalSnapshot(capabilities: [capability(), capability()]))

    let failed = await waitUntil { model.lifecycleState == .failed }
    XCTAssertTrue(failed)
    XCTAssertNil(model.presentationStore.presentedSheet)
  }

  func testPresentationRefreshAndConnectionActionsReachBackend() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)

    let refreshed = await model.presentationStore.perform(.refresh(.tasks))
    let tested = await model.presentationStore.perform(.testConnection)
    let paused = await model.presentationStore.perform(.setReceivingPaused(true))
    XCTAssertTrue(refreshed)
    XCTAssertTrue(tested)
    XCTAssertTrue(paused)
    try? await model.connect()
    try? await model.disconnect()

    let events = await backend.events()
    XCTAssertEqual(
      events,
      [.refresh(.tasks), .testConnection, .receivingPaused(true), .connect, .disconnect]
    )
  }

  func testSubmitSteerInterruptAndOpenCodexPreserveTypedArguments() async throws {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    let submission = taskSubmission()
    let steer = BridgeAppSteerRequest(
      taskID: "task-1",
      expectedTurnID: "turn-1",
      input: "继续验证"
    )

    let receipt = try await model.submit(submission)
    try await model.steer(steer)
    let interrupted = await model.presentationStore.perform(.interruptTask("task-1"))
    let authorized = await model.presentationStore.perform(.authorizeTaskVerification("task-1"))
    let openedTask = await model.presentationStore.perform(.openTaskInCodex("task-1"))
    let loadedEvidence = await model.presentationStore.perform(.loadTaskEvidence("task-1"))
    let openedThread = await model.presentationStore.perform(.openThreadInCodex("thread-1"))
    XCTAssertTrue(interrupted)
    XCTAssertTrue(authorized)
    XCTAssertTrue(openedTask)
    XCTAssertTrue(loadedEvidence)
    XCTAssertTrue(openedThread)

    XCTAssertEqual(receipt, BridgeAppTaskReceipt(taskID: "task-1", reusedExistingTask: false))
    let events = await backend.events()
    XCTAssertEqual(
      events,
      [
        .submit(submission), .steer(steer), .interrupt("task-1"),
        .authorizeVerification("task-1"), .openTask("task-1"),
        .loadTaskEvidence("task-1"), .openThread("thread-1"),
      ]
    )
  }

  func testScopedThreadAndReadOnlyComposerActionsPreserveProjectIdentity() async {
    let backend = TestBackend()
    let model = BridgeAppModel(backend: backend)
    let draft = ReadOnlyTaskDraftPresentation(
      requestID: "local-1",
      projectID: "project-1",
      threadID: "thread-1",
      goal: "Inspect the project",
      acceptanceCriteria: ["Report findings"],
      executionModel: "execution",
      executionEffort: "high",
      supervisorModel: "luna",
      supervisorEffort: "medium"
    )

    let selected = await model.presentationStore.perform(.selectThreadProject("project-1"))
    let read = await model.presentationStore.perform(
      .readBoundThreadHistory(projectID: "project-1", threadID: "thread-1")
    )
    let opened = await model.presentationStore.perform(
      .openBoundThreadInCodex(projectID: "project-1", threadID: "thread-1")
    )
    let prepared = await model.presentationStore.perform(
      .prepareReadOnlyTask(projectID: "project-1", threadID: "thread-1")
    )
    let submitted = await model.presentationStore.perform(.submitReadOnlyTask(draft))
    XCTAssertTrue(selected)
    XCTAssertTrue(read)
    XCTAssertTrue(opened)
    XCTAssertTrue(prepared)
    XCTAssertTrue(submitted)

    let events = await backend.events()
    XCTAssertEqual(
      events,
      [
        .selectThreadProject("project-1"),
        .readBoundHistory(projectID: "project-1", threadID: "thread-1"),
        .openBoundThread(projectID: "project-1", threadID: "thread-1"),
        .prepareReadOnly(projectID: "project-1", threadID: "thread-1"),
        .submitReadOnly(draft),
      ]
    )
  }
}
