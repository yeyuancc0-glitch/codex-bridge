import BridgeIPC
import Foundation
import XCTest

@testable import BridgeServiceAppCore

final class ApprovalPresentationTests: XCTestCase {
  func testTaskAndDirectIdentifiersRemainDistinct() {
    let task = ApprovalPresentation.task(taskApproval())
    let direct = ApprovalPresentation.direct(directApproval())

    XCTAssertEqual(task.id, .task("task-approval"))
    XCTAssertEqual(direct.id, .direct("direct-approval"))
    XCTAssertEqual(task.id.stableKey, "task:task-approval")
    XCTAssertEqual(direct.id.stableKey, "direct:direct-approval")
    XCTAssertFalse(task.isDirect)
    XCTAssertTrue(direct.isDirect)
  }

  func testTaskDetailsIncludeSecurityContext() {
    let item = ApprovalPresentation.task(taskApproval(), projectName: "Bridge")

    XCTAssertTrue(item.rowText.contains("安全审批"))
    XCTAssertTrue(item.detailText.contains("类型：任务审批（permissions）"))
    XCTAssertTrue(item.detailText.contains("项目：Bridge"))
    XCTAssertTrue(item.detailText.contains("请求内容：写入 Sources/App.swift"))
    XCTAssertTrue(item.detailText.contains("目标路径：Sources/App.swift"))
  }

  func testDirectDetailsIncludeProjectAndSummary() {
    let item = ApprovalPresentation.direct(directApproval(), projectName: "Bridge")

    XCTAssertTrue(item.rowText.contains("Direct 审批"))
    XCTAssertTrue(item.detailText.contains("项目：Bridge"))
    XCTAssertTrue(item.detailText.contains("摘要：运行受控命令"))
    XCTAssertTrue(item.detailText.contains("创建时间："))
    XCTAssertEqual(item.allowDecisions, ["allow"])
  }

  func testTaskAllowDecisionsUseDefaultsAndFilterDeny() {
    XCTAssertEqual(
      ApprovalPresentation.task(
        taskApproval(kind: "task_start", decisionOptions: nil)
      ).allowDecisions,
      ["allow"]
    )
    XCTAssertEqual(
      ApprovalPresentation.task(
        taskApproval(kind: "command", decisionOptions: nil)
      ).allowDecisions,
      ["allow"]
    )
    XCTAssertEqual(
      ApprovalPresentation.task(
        taskApproval(
          kind: "command",
          decisionOptions: ["allow", "deny", "allow_for_session", "allow"]
        )
      ).allowDecisions,
      ["allow", "allow_for_session"]
    )
    XCTAssertEqual(
      ApprovalPresentation.task(
        taskApproval(kind: "permissions", decisionOptions: ["deny"])
      ).allowDecisions,
      []
    )
  }

  func testDecisionLabelsKeepUnknownValuesVisible() {
    XCTAssertEqual(ApprovalPresentation.decisionLabel("allow"), "仅本次允许")
    XCTAssertEqual(ApprovalPresentation.decisionLabel("allow_for_session"), "本次会话允许")
    XCTAssertEqual(ApprovalPresentation.decisionLabel("allow_similar_commands"), "允许此类命令")
    XCTAssertEqual(ApprovalPresentation.decisionLabel("deny"), "拒绝")
    XCTAssertEqual(ApprovalPresentation.decisionLabel("future_policy"), "未知决策：future_policy")
  }

  private func taskApproval(
    kind: String = "permissions",
    decisionOptions: [String]? = ["allow", "deny"]
  ) -> IPCApprovalSummary {
    IPCApprovalSummary(
      approvalID: "task-approval",
      taskID: "task-1",
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1",
      kind: kind,
      title: "请求访问工作区",
      summary: "Provider 请求修改项目文件。",
      displayCommand: "写入 Sources/App.swift",
      relativePaths: ["Sources/App.swift"],
      reason: "当前任务需要更新实现。",
      decisionOptions: decisionOptions
    )
  }

  private func directApproval() -> IPCPendingDirectApproval {
    IPCPendingDirectApproval(
      approvalID: "direct-approval",
      projectID: "project-1",
      kind: "command",
      summary: "运行受控命令",
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }
}
