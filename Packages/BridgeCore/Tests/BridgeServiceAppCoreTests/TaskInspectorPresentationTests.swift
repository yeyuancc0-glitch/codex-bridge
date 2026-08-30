import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class TaskInspectorPresentationTests: XCTestCase {
  func testMetadataIncludesTaskContextAndOptionalExecutionDetails() {
    let task = MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      source: "mcp.client",
      sourceClientID: MCPClientID.qwenStudio.rawValue,
      status: "running",
      providerID: "opencode",
      executionModel: "gpt-5.4",
      executionEffort: "high",
      networkAccess: true,
      currentStep: "正在运行测试",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-30T00:00:00Z"
    )

    let text = TaskInspectorPresentation.metadata(for: task, projectName: "Bridge")

    XCTAssertTrue(text.contains("状态：running"))
    XCTAssertTrue(text.contains("Provider：OpenCode"))
    XCTAssertTrue(text.contains("项目：Bridge"))
    XCTAssertTrue(text.contains("模型：gpt-5.4"))
    XCTAssertTrue(text.contains("当前步骤：正在运行测试"))
    XCTAssertTrue(text.contains("网络访问：允许"))
  }

  func testConversationTextRendersRolesAndToolDetails() {
    let userEntry = TaskConversationModel.Entry(
      key: "user:1",
      role: "user",
      kind: "text",
      content: "检查测试",
      isFinal: true
    )
    var toolEntry = TaskConversationModel.Entry(
      key: "agent:1",
      role: "agent",
      kind: "tool",
      content: "测试完成",
      isFinal: true
    )
    toolEntry.toolName = "run_tests"
    toolEntry.toolStatus = "completed"
    let entries = [userEntry, toolEntry]

    XCTAssertEqual(
      TaskInspectorPresentation.conversationText(entries: entries, isStreaming: false),
      "用户：检查测试\r\n\r\nAgent：[工具：run_tests（completed）]\r\n测试完成"
    )
  }

  func testSteerValidationRejectsEmptyAndInvalidInput() {
    XCTAssertNil(TaskInspectorPresentation.steerValidationMessage("继续检查"))
    XCTAssertEqual(
      TaskInspectorPresentation.steerValidationMessage(" \r\n"),
      "补充指令不能为空。"
    )
    XCTAssertEqual(
      TaskInspectorPresentation.steerValidationMessage(String(repeating: "a", count: 32_769)),
      "补充指令超过 32768 字节限制。"
    )
    XCTAssertEqual(
      TaskInspectorPresentation.steerValidationMessage("前\0后"),
      "补充指令包含非法空字符。"
    )
  }

  func testTaskActionAvailabilityFollowsExpectedControlID() {
    let codex = task(status: "running", providerID: "codex", turnID: "turn-1")
    let agent = task(status: "running", providerID: "opencode", providerRunID: "run-1")
    let completed = task(status: "completed", providerID: "opencode", providerRunID: "run-1")

    XCTAssertTrue(TaskInspectorPresentation.canInterrupt(codex))
    XCTAssertFalse(
      TaskInspectorPresentation.canSteer(codex, providerSupportsSteer: true)
    )
    XCTAssertTrue(
      TaskInspectorPresentation.canSteer(agent, providerSupportsSteer: true)
    )
    XCTAssertFalse(
      TaskInspectorPresentation.canSteer(agent, providerSupportsSteer: false)
    )
    XCTAssertFalse(TaskInspectorPresentation.canInterrupt(completed))
  }

  func testTaskActionResultOnlyAppliesToOriginalSelection() {
    XCTAssertTrue(
      TaskInspectorPresentation.shouldApplyTaskActionResult(
        for: "task-1",
        selectedTaskID: "task-1"
      )
    )
    XCTAssertFalse(
      TaskInspectorPresentation.shouldApplyTaskActionResult(
        for: "task-1",
        selectedTaskID: "task-2"
      )
    )
    XCTAssertFalse(
      TaskInspectorPresentation.shouldApplyTaskActionResult(
        for: "task-1",
        selectedTaskID: nil
      )
    )
  }

  private func task(
    status: String,
    providerID: String,
    turnID: String? = nil,
    providerRunID: String? = nil
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: "task-\(status)-\(providerID)",
      projectID: "project-1",
      status: status,
      providerID: providerID,
      turnID: turnID,
      providerRunID: providerRunID,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-30T00:00:00Z"
    )
  }
}
