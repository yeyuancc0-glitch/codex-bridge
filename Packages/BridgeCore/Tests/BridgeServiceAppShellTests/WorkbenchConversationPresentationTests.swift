import BridgeIPC
import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchConversationPresentationTests: XCTestCase {
  func testSelectedTaskWinsWhileConversationModelIsTemporarilyEmpty() {
    XCTAssertEqual(
      WorkbenchConversationSource.resolve(
        hasSelectedTask: true,
        historicalEntryCount: 3
      ),
      .task
    )
  }

  func testHistoricalThreadEntryUsesUnifiedConversationEntryShape() {
    let entry = TaskConversationModel.Entry(
      historicalThreadEntry: MCPThreadEntry(
        turnID: "turn-1",
        role: "assistant",
        text: "最终回复"
      ),
      threadID: "thread-1",
      index: 0
    )

    XCTAssertEqual(entry.key, "history:thread-1:0")
    XCTAssertEqual(entry.role, "agent")
    XCTAssertEqual(entry.kind, "agent")
    XCTAssertEqual(entry.content, "最终回复")
    XCTAssertTrue(entry.isFinal)
  }

  func testSelectedCodexTaskWinsOverHistoricalThreadLabel() {
    let task = MCPServiceTaskSnapshot(
      taskID: "codex-task",
      projectID: "project-1",
      status: "completed",
      providerID: "codex",
      threadID: "thread-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-29T00:00:00Z"
    )

    let selected = WorkbenchAgentTaskPickerContent.selectedTask(
      tasks: [task],
      selectedTaskID: task.taskID
    )

    XCTAssertEqual(selected?.taskID, task.taskID)
    XCTAssertTrue(selected?.isCodexTask == true)
  }
}
