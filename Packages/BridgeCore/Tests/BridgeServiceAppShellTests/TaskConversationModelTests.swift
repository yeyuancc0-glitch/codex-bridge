import BridgeIPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class TaskConversationModelTests: XCTestCase {
  func testTaskSourceDisplayNameKeepsLegacyChatGPTAndLabelsQwen() {
    let legacy = taskSnapshot(status: "completed", source: "chatgpt.mcp")
    let chatGPT = taskSnapshot(
      status: "completed",
      source: "mcp.client",
      sourceClientID: MCPClientID.chatGPT.rawValue
    )
    let qwen = taskSnapshot(
      status: "completed",
      source: "mcp.client",
      sourceClientID: MCPClientID.qwenStudio.rawValue
    )

    XCTAssertEqual(legacy.sourceDisplayName, "ChatGPT")
    XCTAssertEqual(chatGPT.sourceDisplayName, "ChatGPT")
    XCTAssertEqual(qwen.sourceDisplayName, "Qwen Studio")
  }

  func testDeepSeekHarnessTaskUsesExperimentalReadOnlyPresentation() {
    let task = taskSnapshot(status: "running", providerID: "deepseek-harness")

    XCTAssertEqual(task.providerDisplayName, "DeepSeek Harness")
    XCTAssertEqual(task.providerSystemImage, "lock.shield.fill")
    XCTAssertTrue(task.isExternalAgentTask)
  }

  func testStartAppliesSubscriptionPageThenAppliesStreamingPushes() async throws {
    let client = TestBridgeServiceClient()
    let model = TaskConversationModel(taskID: "task-1", client: client)

    await model.start()

    XCTAssertEqual(model.subscriptionID, 7)
    XCTAssertEqual(model.entries.map(\.key), ["user:1"])
    XCTAssertEqual(model.entries[0].content, "hello")
    XCTAssertTrue(model.entries[0].isFinal)

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: nil,
        baseContentLength: 0,
        fullContent: "I will inspect",
        final: false
      )
    )
    try await waitUntil { model.entries.count == 2 && model.entries[1].content == "I will inspect" }
    XCTAssertTrue(model.isStreaming)
    XCTAssertFalse(model.entries[1].isFinal)
    let firstScrollRevision = model.scrollRevision

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: " the parser.",
        baseContentLength: 14,
        fullContent: nil,
        final: false
      )
    )
    try await waitUntil { model.entries[1].content == "I will inspect the parser." }
    XCTAssertGreaterThan(model.scrollRevision, firstScrollRevision)

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: " Done.",
        baseContentLength: 26,
        fullContent: nil,
        final: true
      )
    )
    try await waitUntil { !model.isStreaming && model.entries[1].isFinal }
    XCTAssertEqual(model.entries[1].content, "I will inspect the parser. Done.")
  }

  func testMismatchedDeltaIsDroppedButFullContentStillReplaces() async throws {
    let client = TestBridgeServiceClient()
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: "I will inspect",
        baseContentLength: 0,
        fullContent: nil,
        final: false
      )
    )
    try await waitUntil { model.entries.count == 2 }
    XCTAssertEqual(model.entries[1].content, "I will inspect")

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: "ignored",
        baseContentLength: 999,
        fullContent: nil,
        final: false
      )
    )
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.entries[1].content, "I will inspect")

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Authoritative text",
        final: true
      )
    )
    try await waitUntil { !model.isStreaming }
    XCTAssertEqual(model.entries[1].content, "Authoritative text")
  }

  func testMismatchedDeltaTriggersConversationSnapshotResync() async throws {
    let client = TestBridgeServiceClient()
    await client.setConversationPages([
      TestBridgeServiceClient.TaskConversationQuery(
        IPCTaskConversationRequest(taskID: "task-1", limit: 200)
      ): IPCTaskConversationPage(
        taskID: "task-1",
        messages: [
          IPCTaskConversationMessage(messageID: 1, key: "user:1", role: "user", content: "hello"),
          IPCTaskConversationMessage(
            messageID: 2,
            key: "agent:item-1",
            role: "agent",
            content: "Final"
          ),
        ]
      )
    ])
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Recovered",
        final: false
      )
    )
    try await waitUntil { model.entries.count == 2 }

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: " output",
        baseContentLength: 999,
        fullContent: nil,
        final: false
      )
    )

    try await waitUntil { model.entries[1].content == "Final" }
    XCTAssertTrue(model.entries[1].isFinal)
    XCTAssertFalse(model.isStreaming)
  }

  func testMismatchedDeltaRetriesUntilPersistedSnapshotCatchesUp() async throws {
    let client = TestBridgeServiceClient()
    let query = TestBridgeServiceClient.TaskConversationQuery(
      IPCTaskConversationRequest(taskID: "task-1", limit: 200)
    )
    await client.setConversationPages([
      query: IPCTaskConversationPage(
        taskID: "task-1",
        messages: [
          IPCTaskConversationMessage(
            messageID: 2,
            key: "agent:item-1",
            role: "agent",
            content: "A",
            final: false
          )
        ]
      )
    ])
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: nil,
        baseContentLength: 0,
        fullContent: "A",
        final: false
      )
    )
    try await waitUntil { model.entries.count == 2 }
    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: "C",
        baseContentLength: 2,
        fullContent: nil,
        final: false
      )
    )

    _ = Task {
      try? await Task.sleep(for: .milliseconds(250))
      await client.setConversationPages([
        query: IPCTaskConversationPage(
          taskID: "task-1",
          messages: [
            IPCTaskConversationMessage(
              messageID: 2,
              key: "agent:item-1",
              role: "agent",
              content: "AB",
              final: false
            )
          ]
        )
      ])
    }

    try await waitUntil(timeout: .seconds(2)) { model.entries[1].content == "ABC" }
    XCTAssertTrue(model.isStreaming)
  }

  func testRunningConversationSnapshotKeepsPersistedProviderEntriesActive() async throws {
    let client = TestBridgeServiceClient()
    await client.setSubscriptionPage(
      IPCTaskConversationPage(
        taskID: "task-1",
        messages: [
          IPCTaskConversationMessage(
            messageID: 1,
            key: "user:1",
            role: "user",
            kind: "user",
            content: "Build the project",
            final: true
          ),
          IPCTaskConversationMessage(
            messageID: 2,
            key: "agent:partial",
            role: "agent",
            kind: "agent",
            content: "Partial response",
            final: false
          ),
          IPCTaskConversationMessage(
            messageID: 3,
            key: "reasoning:partial",
            role: "agent",
            kind: "reasoning",
            content: "Partial reasoning",
            final: false
          ),
          IPCTaskConversationMessage(
            messageID: 4,
            key: "tool:completed",
            role: "agent",
            kind: "tool_call",
            content: "Completed tool",
            toolName: "read",
            toolStatus: "completed",
            final: true
          ),
          IPCTaskConversationMessage(
            messageID: 5,
            key: "tool:active",
            role: "agent",
            kind: "tool_call",
            content: "Active tool",
            toolName: "write",
            toolStatus: "inProgress",
            final: false
          ),
        ]
      )
    )
    let model = TaskConversationModel(taskID: "task-1", client: client)

    await model.start()

    XCTAssertEqual(model.entries.map(\.isFinal), [true, false, false, true, false])
    XCTAssertEqual(model.activity, .executing("write"))
    XCTAssertTrue(model.isStreaming)
  }

  func testActivityTracksReasoningAndToolsUntilEveryEntryIsFinal() async throws {
    let client = TestBridgeServiceClient()
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "reasoning:item-1",
        role: "agent",
        kind: "reasoning",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Inspecting",
        final: false
      )
    )
    try await waitUntil { model.activity == .thinking }

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "tool:item-2",
        role: "agent",
        kind: "tool_call",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Running tests",
        final: false,
        toolName: "exec_command",
        toolStatus: "in_progress"
      )
    )
    try await waitUntil { model.activity == .executing("exec_command") }

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "tool:item-2",
        role: "agent",
        kind: "tool_call",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Tests passed",
        final: true,
        toolName: "exec_command",
        toolStatus: "completed"
      )
    )
    try await waitUntil { model.activity == .thinking }
    XCTAssertTrue(model.isStreaming)

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "reasoning:item-1",
        role: "agent",
        kind: "reasoning",
        delta: nil,
        baseContentLength: 0,
        fullContent: "Inspection complete",
        final: true
      )
    )
    try await waitUntil { model.activity == .idle }
    XCTAssertFalse(model.isStreaming)
  }

  func testTaskStateKeepsActivityVisibleUntilTerminalStatus() {
    let running = taskSnapshot(status: "running")
    let completed = taskSnapshot(status: "completed")

    let thinking = CodexActivityPresentation(task: running, activity: .idle)
    XCTAssertTrue(thinking.isActive)
    XCTAssertTrue(thinking.showsBubble)
    XCTAssertEqual(thinking.statusText, "Codex 正在思考…")

    let finished = CodexActivityPresentation(task: completed, activity: .thinking)
    XCTAssertFalse(finished.isActive)
    XCTAssertFalse(finished.showsBubble)
    XCTAssertEqual(finished.statusText, "Codex 已完成")
  }

  func testOpenCodeTaskPresentationUsesProviderStateWithoutCodexSemantics() {
    let task = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      status: "failed",
      providerID: "opencode",
      installationID: "installation-1",
      executionModel: "provider-model",
      executionEffort: "high",
      providerSessionID: "session-1",
      providerRunID: "run-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      resultSummary: "ACP session ended",
      failureCode: "provider_session_failed",
      updatedAt: "2026-08-20T00:00:00Z"
    )

    XCTAssertEqual(task.providerIdentifier, "opencode")
    XCTAssertEqual(task.providerDisplayName, "OpenCode")
    XCTAssertTrue(task.isExternalAgentTask)
    XCTAssertFalse(task.isCodexTask)
    XCTAssertEqual(task.failureDescription, "provider_session_failed：ACP session ended")

    let activity = CodexActivityPresentation(task: task, activity: .idle)
    XCTAssertEqual(activity.statusText, "OpenCode 执行失败")
    XCTAssertFalse(activity.statusText.contains("Codex"))
    XCTAssertFalse(activity.isActive)
  }

  func testOpenCodeLocalApprovalIsAnActiveTask() {
    let task = taskSnapshot(status: "awaiting_local_approval", providerID: "opencode")
    let activity = CodexActivityPresentation(task: task, activity: .idle)

    XCTAssertTrue(task.isActive)
    XCTAssertTrue(activity.isActive)
    XCTAssertTrue(activity.showsBubble)
    XCTAssertEqual(activity.statusText, "等待本机批准 OpenCode 任务…")
  }

  func testUnknownKeyDeltaWithNonzeroBaseIsIgnored() async throws {
    let client = TestBridgeServiceClient()
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-9",
        role: "agent",
        delta: "orphan delta",
        baseContentLength: 12,
        fullContent: nil,
        final: false
      )
    )
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.entries.count, 1)
  }

  func testSubscribeFailureFallsBackToPlainPage() async throws {
    let client = TestBridgeServiceClient()
    await client.setFailSubscription(true)
    await client.setConversationPages([
      TestBridgeServiceClient.TaskConversationQuery(
        IPCTaskConversationRequest(taskID: "task-1", limit: 200)):
        IPCTaskConversationPage(
          taskID: "task-1",
          messages: [
            IPCTaskConversationMessage(messageID: 1, key: "user:1", role: "user", content: "hi"),
            IPCTaskConversationMessage(
              messageID: 2, key: "agent:item-1", role: "agent", content: "yo"),
          ]
        )
    ])
    let model = TaskConversationModel(taskID: "task-1", client: client)

    await model.start()

    XCTAssertEqual(model.entries.map(\.key), ["user:1", "agent:item-1"])
    XCTAssertNotNil(model.errorMessage)
  }

  func testLoadEarlierPrependsOlderMessagesWithoutDuplicatingKnownKeys() async throws {
    let client = TestBridgeServiceClient()
    await client.setSubscriptionPage(
      IPCTaskConversationPage(
        taskID: "task-1",
        messages: [
          IPCTaskConversationMessage(messageID: 3, key: "user:2", role: "user", content: "second"),
          IPCTaskConversationMessage(
            messageID: 4, key: "agent:item-2", role: "agent", content: "reply"),
        ]
      )
    )
    await client.setConversationPages([
      TestBridgeServiceClient.TaskConversationQuery(
        IPCTaskConversationRequest(taskID: "task-1", beforeMessageID: 3, limit: 100)
      ): IPCTaskConversationPage(
        taskID: "task-1",
        messages: [
          IPCTaskConversationMessage(messageID: 1, key: "user:1", role: "user", content: "first"),
          IPCTaskConversationMessage(
            messageID: 2, key: "user:2", role: "user", content: "stale copy"),
        ]
      )
    ])
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()
    XCTAssertEqual(model.entries.count, 2)

    await model.loadEarlier()

    XCTAssertEqual(model.entries.map(\.key), ["user:1", "user:2", "agent:item-2"])
    XCTAssertEqual(model.entries[1].content, "second")
  }

  func testCancelStopsStreamingTask() async throws {
    let client = TestBridgeServiceClient()
    let model = TaskConversationModel(taskID: "task-1", client: client)
    await model.start()
    model.cancel()
    try await Task.sleep(for: .milliseconds(100))

    await client.pushConversation(
      IPCTaskConversationPush(
        taskID: "task-1",
        key: "agent:item-1",
        role: "agent",
        delta: "late",
        baseContentLength: 0,
        fullContent: nil,
        final: false
      )
    )
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.entries.count, 1)
  }

  func testCancelWhileSubscriptionStartsCleansUpLateSubscription() async throws {
    let client = TestBridgeServiceClient()
    await client.setSubscriptionDelay(.milliseconds(100))
    let model = TaskConversationModel(taskID: "task-1", client: client)
    let start = Task { await model.start() }

    try await Task.sleep(for: .milliseconds(20))
    model.cancel()
    await start.value

    XCTAssertEqual(model.subscriptionID, -1)
    let unsubscribed = await client.unsubscribedSubscriptionIDsValue()
    XCTAssertEqual(unsubscribed, [7])
  }

  func testThreadTurnGroupGrouping() {
    let entries: [MCPThreadEntry] = [
      MCPThreadEntry(turnID: "turn-1", role: "user", text: "Please research X"),
      MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "First, finding account"),
      MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "Second, parsing timeline"),
      MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "Here is the summary of X: ..."),
    ]

    let groups = ThreadTurnGroup.group(entries: entries)
    XCTAssertEqual(groups.count, 2)

    XCTAssertEqual(groups[0].role, "user")
    XCTAssertEqual(groups[0].mainText, "Please research X")
    XCTAssertTrue(groups[0].thoughts.isEmpty)

    XCTAssertEqual(groups[1].role, "assistant")
    XCTAssertEqual(groups[1].thoughts, ["First, finding account", "Second, parsing timeline"])
    XCTAssertEqual(groups[1].mainText, "Here is the summary of X: ...")
  }

  func testThreadTurnGroupMultipleTurns() {
    let entries: [MCPThreadEntry] = [
      MCPThreadEntry(turnID: "turn-1", role: "user", text: "Hello"),
      MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "Hi there!"),
      MCPThreadEntry(turnID: "turn-2", role: "user", text: "Check disk space"),
      MCPThreadEntry(turnID: "turn-2", role: "assistant", text: "Running df -h"),
      MCPThreadEntry(turnID: "turn-2", role: "assistant", text: "You have 100GB available."),
    ]

    let groups = ThreadTurnGroup.group(entries: entries)
    XCTAssertEqual(groups.count, 4)

    XCTAssertEqual(groups[0].role, "user")
    XCTAssertEqual(groups[0].mainText, "Hello")

    XCTAssertEqual(groups[1].role, "assistant")
    XCTAssertEqual(groups[1].mainText, "Hi there!")
    XCTAssertTrue(groups[1].thoughts.isEmpty)

    XCTAssertEqual(groups[2].role, "user")
    XCTAssertEqual(groups[2].mainText, "Check disk space")

    XCTAssertEqual(groups[3].role, "assistant")
    XCTAssertEqual(groups[3].thoughts, ["Running df -h"])
    XCTAssertEqual(groups[3].mainText, "You have 100GB available.")
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }

  private func taskSnapshot(
    status: String,
    source: String? = nil,
    sourceClientID: String? = nil,
    providerID: String? = nil
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      source: source,
      sourceClientID: sourceClientID,
      status: status,
      providerID: providerID,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-20T00:00:00Z"
    )
  }
}
