import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchApprovalPresentationTests: XCTestCase {
  func testFirstPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: [],
        current: ["codex:approval-1"]
      )
    )
  }

  func testAdditionalPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1", "direct:approval-1"]
      )
    )
  }

  func testUnchangedOrResolvedApprovalsDoNotRequestReveal() {
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1"]
      )
    )
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: []
      )
    )
  }

  func testTranscriptToolPresentationUsesCodexStyleActivityLabels() {
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "read_files", status: "completed"),
      CodexTranscriptToolPresentation(title: "已读取文件", systemImage: "book")
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "file_change", status: "inProgress"),
      CodexTranscriptToolPresentation(title: "正在编辑文件", systemImage: "pencil")
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "command_execution", status: "failed"),
      CodexTranscriptToolPresentation(title: "已运行命令", systemImage: "terminal")
    )
  }

  func testTaskModelPresentationUsesActualTaskValues() {
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "gpt-5.6-luna",
        effort: "max",
        displayName: "Luna"
      ),
      "Luna · Max"
    )
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "gpt-5.6-sol",
        effort: "high",
        displayName: nil
      ),
      "gpt-5.6-sol · High"
    )
    XCTAssertNil(
      WorkbenchTaskModelPresentation.label(
        modelID: nil,
        effort: "high",
        displayName: nil
      )
    )
  }
}
