import XCTest

@testable import BridgePresentation

@MainActor
final class BridgePresentationStoreTests: XCTestCase {
  func testRenderReconcilesTaskAndProjectSelection() {
    let recorder = ActionRecorder()
    let initial = snapshot(
      tasks: [task(id: "task-1"), task(id: "task-2")],
      projects: [project(id: "project-1"), project(id: "project-2")]
    )
    let store = BridgePresentationStore(snapshot: initial, actionHandler: recorder)

    XCTAssertEqual(store.selectedTaskID, "task-1")
    XCTAssertEqual(store.selectedProjectID, "project-1")

    store.selectTask("task-2")
    store.selectProject("project-2")
    store.render(initial)

    XCTAssertEqual(store.selectedTaskID, "task-2")
    XCTAssertEqual(store.selectedProjectID, "project-2")

    store.render(snapshot(tasks: [task(id: "task-3")], projects: []))

    XCTAssertEqual(store.selectedTaskID, "task-3")
    XCTAssertNil(store.selectedProjectID)
  }

  func testTaskRouteWaitsForSnapshotThenSelectsExactTask() {
    let recorder = ActionRecorder()
    let store = BridgePresentationStore(actionHandler: recorder)

    store.openTaskRoute("task-2")

    XCTAssertEqual(store.destination, .tasks)
    XCTAssertNil(store.selectedTaskID)
    store.render(snapshot(tasks: [task(id: "task-1"), task(id: "task-2")], projects: []))
    XCTAssertEqual(store.selectedTaskID, "task-2")
  }

  func testManualTaskSelectionCancelsPendingTaskRoute() {
    let recorder = ActionRecorder()
    let initial = snapshot(tasks: [task(id: "task-1")], projects: [])
    let store = BridgePresentationStore(snapshot: initial, actionHandler: recorder)

    store.openTaskRoute("task-2")
    store.selectTask("task-1")
    store.render(snapshot(tasks: [task(id: "task-1"), task(id: "task-2")], projects: []))

    XCTAssertEqual(store.selectedTaskID, "task-1")
  }

  func testTaskDecisionUsesEditedModelAndEffort() async {
    let recorder = ActionRecorder()
    let store = BridgePresentationStore(actionHandler: recorder)
    store.presentTaskConfirmation(confirmation())

    store.updateConfirmationModel("gpt-5.6")
    store.updateConfirmationEffort("high")
    await store.decideTask(.runReadOnly)

    let actions = await recorder.recordedActions()
    XCTAssertEqual(
      actions,
      [
        .decideTask(
          requestID: "request-1",
          decision: .runReadOnly,
          model: "gpt-5.6",
          effort: "high"
        )
      ]
    )
    XCTAssertNil(store.presentedSheet)
  }

  func testInvalidTaskPickerValuesAreRejectedLocally() {
    let recorder = ActionRecorder()
    let store = BridgePresentationStore(actionHandler: recorder)
    store.presentTaskConfirmation(confirmation())

    store.updateConfirmationModel("invented-model")
    store.updateConfirmationEffort("impossible")

    guard case .taskConfirmation(let value) = store.presentedSheet else {
      return XCTFail("Expected task confirmation")
    }
    XCTAssertEqual(value.executionModel, "gpt-5.6-codex")
    XCTAssertEqual(value.effort, "medium")
  }

  func testTaskStartFailsClosedWhenCatalogNoLongerContainsSelection() async {
    let recorder = ActionRecorder()
    let store = BridgePresentationStore(actionHandler: recorder)
    let stale = TaskConfirmationPresentation(
      id: "stale-request",
      goal: "目标",
      acceptanceCriteria: ["验收"],
      projectName: "项目",
      threadDescription: "新线程",
      executionModel: "removed-model",
      effort: "medium",
      permissionMode: "read-only",
      networkAllowed: false,
      supervisorModel: "luna",
      estimatedReadScope: [],
      riskMessages: [],
      availableModels: [],
      availableEfforts: ["medium"]
    )
    store.presentTaskConfirmation(stale)

    await store.decideTask(.start)

    let actions = await recorder.recordedActions()
    XCTAssertTrue(actions.isEmpty)
    XCTAssertNotNil(store.presentedSheet)
  }

  func testBlockedApprovalCannotBeAllowed() async {
    let recorder = ActionRecorder()
    let store = BridgePresentationStore(actionHandler: recorder)
    store.presentCodexApproval(approval(canAllow: false))

    await store.decideApproval(.allowOnce)

    let actions = await recorder.recordedActions()
    XCTAssertTrue(actions.isEmpty)
    XCTAssertNotNil(store.presentedSheet)
  }

  func testFailedApprovalActionKeepsDecisionVisible() async {
    let recorder = ActionRecorder(failureMessage: "persistence barrier unavailable")
    let store = BridgePresentationStore(actionHandler: recorder)
    store.presentCodexApproval(approval(canAllow: true))

    await store.decideApproval(.deny)

    XCTAssertNotNil(store.presentedSheet)
    XCTAssertEqual(store.actionError?.title, "操作未完成")
    XCTAssertEqual(store.actionError?.message, "persistence barrier unavailable")
    XCTAssertFalse(store.isPerformingSheetAction)
  }

  func testAllExplicitLoadStatesSurviveProjection() {
    let recorder = ActionRecorder()
    let error = PresentationErrorState(title: "连接失败", message: "Tunnel helper 未就绪")
    let empty = PresentationEmptyState(
      title: "暂无任务",
      message: "从 ChatGPT 提交任务后会显示在这里。",
      systemImage: "checklist"
    )
    let value = BridgePresentationSnapshot(
      overview: .loading(message: "正在检查"),
      tasks: .empty(empty),
      projects: .failed(error),
      threads: .loading(message: "正在读取"),
      approvals: .loading(message: "正在读取"),
      connections: .loading(message: "正在读取"),
      logs: .loading(message: "正在读取"),
      settings: .loading(message: "正在读取")
    )
    let store = BridgePresentationStore(actionHandler: recorder)

    store.render(value)

    XCTAssertEqual(store.snapshot.tasks, .empty(empty))
    XCTAssertEqual(store.snapshot.projects, .failed(error))
    XCTAssertEqual(store.snapshot.overview, .loading(message: "正在检查"))
  }
}

private actor ActionRecorder: BridgePresentationActionHandling {
  private var actions: [PresentationAction] = []
  private let failureMessage: String?

  init(failureMessage: String? = nil) {
    self.failureMessage = failureMessage
  }

  func handle(_ action: PresentationAction) async throws {
    actions.append(action)
    if let failureMessage {
      throw ActionFailure(message: failureMessage)
    }
  }

  func recordedActions() -> [PresentationAction] {
    actions
  }
}

private struct ActionFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private func task(id: String) -> TaskRowPresentation {
  TaskRowPresentation(
    id: id,
    title: "任务 \(id)",
    projectName: "Codex Bridge",
    threadLabel: "thread-1",
    status: .running,
    model: "gpt-5.6-codex",
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
}

private func project(id: String) -> ProjectPresentation {
  ProjectPresentation(
    id: id,
    name: "项目 \(id)",
    normalizedPath: "/tmp/\(id)",
    isDirty: false,
    canRead: true,
    canWrite: false,
    networkAllowed: false,
    requiresLocalConfirmation: true,
    threadCount: 0,
    isAvailable: true
  )
}

private func snapshot(
  tasks: [TaskRowPresentation],
  projects: [ProjectPresentation]
) -> BridgePresentationSnapshot {
  BridgePresentationSnapshot(
    overview: .loading(message: "正在读取"),
    tasks: .ready(TaskPagePresentation(tasks: tasks, details: [])),
    projects: .ready(ProjectPagePresentation(projects: projects)),
    threads: .loading(message: "正在读取"),
    approvals: .loading(message: "正在读取"),
    connections: .loading(message: "正在读取"),
    logs: .loading(message: "正在读取"),
    settings: .loading(message: "正在读取")
  )
}

private func confirmation() -> TaskConfirmationPresentation {
  TaskConfirmationPresentation(
    id: "request-1",
    goal: "完成连接器 Presentation 层",
    acceptanceCriteria: ["编译通过"],
    projectName: "Codex Bridge",
    threadDescription: "新线程",
    executionModel: "gpt-5.6-codex",
    effort: "medium",
    permissionMode: "workspace-write",
    networkAllowed: false,
    supervisorModel: "gpt-5.6-luna",
    estimatedReadScope: ["Packages/BridgeCore"],
    riskMessages: [],
    availableModels: ["gpt-5.6-codex", "gpt-5.6"],
    availableEfforts: ["medium", "high"]
  )
}

private func approval(canAllow: Bool) -> CodexApprovalPresentation {
  CodexApprovalPresentation(
    id: "approval-1",
    source: "Codex Execution",
    threadID: "thread-1",
    turnID: "turn-1",
    operationTitle: "运行验证",
    commandArguments: ["/usr/bin/git", "status", "--short"],
    workingDirectory: "/tmp/project",
    reason: "收集 Git 状态",
    supervisorRisk: "低风险，只读",
    consequences: ["读取仓库元数据"],
    canAllow: canAllow
  )
}
