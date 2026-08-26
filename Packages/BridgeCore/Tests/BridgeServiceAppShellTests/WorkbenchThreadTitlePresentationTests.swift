import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchThreadTitlePresentationTests: XCTestCase {
  func testShortTitleRemainsUnchanged() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact("短会话", maximumCharacters: 28),
      "短会话"
    )
  }

  func testWhitespaceIsCollapsedForSingleLinePresentation() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(
        "第一行\n  第二行\t第三行",
        maximumCharacters: 48
      ),
      "第一行 第二行 第三行"
    )
  }

  func testLongTitleIsCappedWithEllipsis() {
    let compact = WorkbenchThreadTitlePresentation.compact(
      String(repeating: "长", count: 30),
      maximumCharacters: 8
    )

    XCTAssertEqual(compact, "长长长长长长长…")
    XCTAssertEqual(compact.count, 8)
  }

  func testWhitespaceOnlyTitleUsesFallback() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(" \n\t ", maximumCharacters: 28),
      "未命名会话"
    )
  }

  func testExternalTaskCardDoesNotRenderTheFullResultSummary() {
    let task = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      source: nil,
      sourceClientID: nil,
      status: "completed",
      providerID: "opencode",
      installationID: nil,
      executionModel: nil,
      executionEffort: nil,
      threadID: nil,
      turnID: nil,
      providerSessionID: nil,
      providerRunID: nil,
      permissionMode: nil,
      networkAccess: false,
      currentStep: nil,
      changedFiles: [],
      recentEvents: [],
      recentActivity: [],
      recentActivityAvailable: true,
      supervisorStatus: "disabled",
      supervisorSummary: nil,
      localApprovalRequired: false,
      resultSummary: String(repeating: "long report content ", count: 200),
      failureCode: nil,
      updatedAt: "2026-08-26T00:00:00Z"
    )

    let preview = try? XCTUnwrap(WorkbenchTaskTextPresentation.cardTitle(for: task))
    XCTAssertEqual(preview?.count, 240)
    XCTAssertTrue(preview?.hasSuffix("…") == true)
    XCTAssertLessThan(
      WorkbenchTaskTextPresentation.menuTitle(for: task).count,
      task.resultSummary?.count ?? 0
    )
  }

  func testExternalTaskCardBoundsTheCurrentStepPreview() {
    let task = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      source: nil,
      sourceClientID: nil,
      status: "running",
      providerID: "opencode",
      installationID: nil,
      executionModel: nil,
      executionEffort: nil,
      threadID: nil,
      turnID: nil,
      providerSessionID: nil,
      providerRunID: nil,
      permissionMode: nil,
      networkAccess: false,
      currentStep: String(repeating: "step ", count: 100),
      changedFiles: [],
      recentEvents: [],
      recentActivity: [],
      recentActivityAvailable: true,
      supervisorStatus: "disabled",
      supervisorSummary: nil,
      localApprovalRequired: false,
      resultSummary: nil,
      failureCode: nil,
      updatedAt: "2026-08-26T00:00:00Z"
    )

    guard let preview = WorkbenchTaskTextPresentation.cardTitle(for: task) else {
      XCTFail("Expected a bounded current-step preview")
      return
    }
    XCTAssertEqual(preview.count, 240)
    XCTAssertTrue(preview.hasSuffix("…"))
  }
}
