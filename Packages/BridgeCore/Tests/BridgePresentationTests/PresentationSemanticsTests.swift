import XCTest

@testable import BridgePresentation

final class PresentationSemanticsTests: XCTestCase {
  func testSidebarHasExactlyEightStableUniqueDestinations() {
    let destinations = BridgeNavigationDestination.allCases

    XCTAssertEqual(destinations.count, 8)
    XCTAssertEqual(Set(destinations.map(\.id)).count, 8)
    XCTAssertEqual(Set(destinations.map(\.title)).count, 8)
    XCTAssertTrue(destinations.allSatisfy { !$0.systemImage.isEmpty })
    XCTAssertEqual(
      destinations.map(\.id),
      ["overview", "tasks", "projects", "threads", "approvals", "connections", "logs", "settings"]
    )
  }

  func testEveryStatusHasTextIconAndAccessibleMeaning() {
    let statuses: [PresentationStatus] = [
      .checking, .ready, .running, .waiting, .degraded, .disconnected, .paused, .blocked,
      .failed, .completed,
    ]

    for status in statuses {
      XCTAssertFalse(status.label.isEmpty)
      XCTAssertFalse(status.systemImage.isEmpty)
      XCTAssertTrue(status.accessibilitySummary.contains(status.label))
    }
  }

  func testTaskEvidenceTabsUseStableContentCanonIDs() {
    XCTAssertEqual(
      TaskEvidenceTab.allCases.map(\.id),
      ["summary", "timeline", "commands", "files", "diff", "supervision", "verification", "logs"]
    )
    XCTAssertTrue(TaskEvidenceTab.allCases.allSatisfy { !$0.title.isEmpty })
  }

  func testSheetIDsKeepTaskAndApprovalNamespacesSeparate() {
    let taskSheet = PresentedBridgeSheet.taskConfirmation(confirmationForSemantics())
    let approvalSheet = PresentedBridgeSheet.codexApproval(approvalForSemantics())

    XCTAssertEqual(taskSheet.id, "task-confirmation-same-id")
    XCTAssertEqual(approvalSheet.id, "codex-approval-same-id")
    XCTAssertNotEqual(taskSheet.id, approvalSheet.id)
  }

  func testApprovalPresentationFailsClosedWithoutCompleteEvidence() {
    let approval = CodexApprovalPresentation(
      id: "approval",
      source: "Codex",
      threadID: "thread",
      turnID: "turn",
      operationTitle: "未明确操作",
      workingDirectory: "/tmp/project",
      reason: "原因",
      supervisorRisk: "未知",
      consequences: [],
      canAllow: true
    )

    XCTAssertFalse(approval.canAllow)
  }

  func testCapabilityDefaultsPreserveExistingPresentationBehavior() {
    let connection = ConnectionPagePresentation(
      mode: "本机",
      endpoint: "127.0.0.1",
      nodes: [],
      receivingPaused: false
    )
    let log = LogPagePresentation(entries: [], isStreaming: false)
    let thread = threadForSemantics()
    let task = taskForSemantics()
    let project = projectForSemantics()

    XCTAssertTrue(connection.canChangeReceiving)
    XCTAssertTrue(connection.canTest)
    XCTAssertTrue(log.canExport)
    XCTAssertTrue(thread.canOpenInCodex)
    XCTAssertTrue(thread.canReadHistory)
    XCTAssertTrue(thread.canContinueNow)
    XCTAssertTrue(thread.canCreateTask)
    XCTAssertEqual(thread.modelDisplayValue, "model")
    XCTAssertTrue(task.canOpenInCodex)
    XCTAssertTrue(task.canRequestInterrupt)
    XCTAssertEqual(project.threadCountDisplayValue, "2")
    XCTAssertTrue(project.gitFactsKnown)
    XCTAssertEqual(project.branchDisplayValue, "非 Git 仓库")
    XCTAssertEqual(project.workingTreeDisplayValue, "干净")
    XCTAssertFalse(project.showsDirtyIndicator)
  }

  func testUnavailableCapabilitiesAndUnknownFactsRemainExplicit() {
    let connection = ConnectionPagePresentation(
      mode: "未配置",
      endpoint: "未绑定",
      nodes: [],
      receivingPaused: false,
      canChangeReceiving: false,
      canTest: false
    )
    let log = LogPagePresentation(entries: [], isStreaming: false, canExport: false)
    let thread = threadForSemantics(
      canOpenInCodex: false,
      canReadHistory: false,
      canContinue: false,
      canCreateTask: false,
      modelIsKnown: false
    )
    let task = taskForSemantics(canOpenInCodex: false, canInterrupt: false)
    let project = projectForSemantics(
      isDirty: true,
      threadCountIsKnown: false,
      gitFactsKnown: false
    )

    XCTAssertFalse(connection.canChangeReceiving)
    XCTAssertFalse(connection.canTest)
    XCTAssertFalse(log.canExport)
    XCTAssertFalse(thread.canOpenInCodex)
    XCTAssertFalse(thread.canReadHistory)
    XCTAssertFalse(thread.canContinueNow)
    XCTAssertFalse(thread.canCreateTask)
    XCTAssertEqual(thread.modelDisplayValue, "未读取")
    XCTAssertFalse(task.canOpenInCodex)
    XCTAssertFalse(task.canRequestInterrupt)
    XCTAssertEqual(project.threadCountDisplayValue, "未读取")
    XCTAssertEqual(project.branchDisplayValue, "Git 状态未读取")
    XCTAssertEqual(project.workingTreeDisplayValue, "Git 状态未读取")
    XCTAssertFalse(project.showsDirtyIndicator)
  }
}

private func confirmationForSemantics() -> TaskConfirmationPresentation {
  TaskConfirmationPresentation(
    id: "same-id",
    goal: "目标",
    acceptanceCriteria: ["验收"],
    projectName: "项目",
    threadDescription: "新线程",
    executionModel: "model",
    effort: "medium",
    permissionMode: "read-only",
    networkAllowed: false,
    supervisorModel: "luna",
    estimatedReadScope: [],
    riskMessages: [],
    availableModels: ["model"],
    availableEfforts: ["medium"]
  )
}

private func approvalForSemantics() -> CodexApprovalPresentation {
  CodexApprovalPresentation(
    id: "same-id",
    source: "Codex",
    threadID: "thread",
    turnID: "turn",
    operationTitle: "操作",
    workingDirectory: "/tmp/project",
    reason: "原因",
    supervisorRisk: "风险",
    consequences: [],
    canAllow: false
  )
}

private func threadForSemantics(
  canOpenInCodex: Bool = true,
  canReadHistory: Bool = true,
  canContinue: Bool = true,
  canCreateTask: Bool = true,
  modelIsKnown: Bool = true
) -> ThreadPresentation {
  ThreadPresentation(
    id: "thread",
    preview: "线程",
    projectName: "项目",
    source: "Codex",
    model: "model",
    status: .ready,
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
    isOccupied: false,
    canOpenInCodex: canOpenInCodex,
    canReadHistory: canReadHistory,
    canContinue: canContinue,
    canCreateTask: canCreateTask,
    modelIsKnown: modelIsKnown
  )
}

private func taskForSemantics(
  canOpenInCodex: Bool = true,
  canInterrupt: Bool = true
) -> TaskDetailPresentation {
  TaskDetailPresentation(
    id: "task",
    title: "任务",
    goal: "目标",
    projectName: "项目",
    threadID: "thread",
    model: "model",
    effort: "medium",
    status: .running,
    supervisorStatus: .ready,
    canOpenInCodex: canOpenInCodex,
    canInterrupt: canInterrupt
  )
}

private func projectForSemantics(
  isDirty: Bool = false,
  threadCountIsKnown: Bool = true,
  gitFactsKnown: Bool = true
) -> ProjectPresentation {
  ProjectPresentation(
    id: "project",
    name: "项目",
    normalizedPath: "/tmp/project",
    isDirty: isDirty,
    canRead: true,
    canWrite: false,
    networkAllowed: false,
    requiresLocalConfirmation: true,
    threadCount: 2,
    isAvailable: true,
    threadCountIsKnown: threadCountIsKnown,
    gitFactsKnown: gitFactsKnown
  )
}
