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
