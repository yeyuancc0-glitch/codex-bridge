import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class ExecutionConversationTests: XCTestCase {
  func testAgentDeltasStreamToSubscribersAndPersistAfterCompletion() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-conversation")
    let manager = makeExecutionManager(script: agentDeltaScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let subscription = try await coordinator.subscribeConversation(taskID: task.id)
    XCTAssertEqual(subscription.page.count, 0)

    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-conversation")
    XCTAssertEqual(binding.turnID, "turn-conversation")

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Final authoritative agent text.")
    try await waitUntil { await collector.count(key: "agent:item-message") == 4 }

    let changes = await collector.all()
    let userSeeds = changes.filter { $0.role == .user }
    XCTAssertEqual(userSeeds.count, 1)
    XCTAssertTrue(userSeeds[0].key.hasPrefix("user:"))
    XCTAssertEqual(
      userSeeds[0].fullContent, "Implement the requested change and report the result.")

    let agentChanges = changes.filter { $0.key == "agent:item-message" }
    XCTAssertEqual(agentChanges.count, 4)
    XCTAssertEqual(agentChanges[0].fullContent, "I will fix")
    XCTAssertEqual(agentChanges[0].baseContentLength, 0)
    XCTAssertEqual(agentChanges[1].delta, " the parser")
    XCTAssertEqual(agentChanges[1].baseContentLength, 10)
    XCTAssertEqual(agentChanges[2].delta, " now.")
    XCTAssertEqual(agentChanges[2].baseContentLength, 21)
    XCTAssertEqual(agentChanges[3].fullContent, "Final authoritative agent text.")
    XCTAssertEqual(agentChanges[3].final, true)

    let page = try await coordinator.conversationPage(taskID: task.id)
    XCTAssertEqual(page.count, 2)
    XCTAssertEqual(page[0].key, userSeeds[0].key)
    XCTAssertEqual(page[1].key, "agent:item-message")
    XCTAssertEqual(page[1].content, "Final authoritative agent text.")

    await coordinator.unsubscribeConversation(
      taskID: task.id,
      subscriptionID: subscription.subscriptionID
    )
    collect.cancel()
  }

  func testConversationPageIsEmptyForUnknownTask() async throws {
    let fixture = try await makeExecutionFixture(self)
    let manager = makeExecutionManager(script: unavailableModelScript())
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }
    do {
      _ = try await coordinator.conversationPage(taskID: TaskID(rawValue: "tsk-unknown"))
      XCTFail("Expected unknownTask error")
    } catch let error as ServiceStoreError {
      guard case .unknownTask = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testFailedTurnCarriesCodexErrorIntoTaskSummary() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-turn-failed")
    let manager = makeExecutionManager(script: failedTurnScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let subscription = try await coordinator.subscribeConversation(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    _ = try await coordinator.start(taskID: task.id)

    let failed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "codex_turn_failed")
    XCTAssertTrue(
      failed.state.resultSummary?.contains("Selected model is at capacity") == true)
    XCTAssertTrue(failed.state.resultSummary?.contains("server_overloaded") == true)

    try await waitUntil { await collector.count() >= 2 }
    let changes = await collector.all()
    XCTAssertTrue(changes.contains { $0.role == .user })
    XCTAssertTrue(
      changes.contains {
        $0.role == .agent && $0.final
          && $0.fullContent?.contains("Selected model is at capacity") == true
      })

    let page = try await coordinator.conversationPage(taskID: task.id)
    XCTAssertTrue(
      page.contains {
        $0.role == .agent && $0.content.contains("Selected model is at capacity")
      })
    collect.cancel()
  }

  func testReasoningAndToolCallsStreamAndPersist() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-rich-conversation"
    )
    let manager = makeExecutionManager(script: richConversationScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let subscription = try await coordinator.subscribeConversation(taskID: task.id)
    XCTAssertEqual(subscription.page.count, 0)

    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    _ = try await coordinator.start(taskID: task.id)

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "The tokenizer is fixed.")

    try await waitUntil { await collector.count(key: "reasoning:reasoning-main") >= 3 }
    try await waitUntil { await collector.count(key: "tool:tool-read") >= 3 }

    let changes = await collector.all()

    let reasoningChanges = changes.filter { $0.key == "reasoning:reasoning-main" }
    XCTAssertEqual(reasoningChanges[0].kind, .reasoning)
    XCTAssertEqual(reasoningChanges[0].fullContent, "I should inspect the parser first.")
    XCTAssertEqual(reasoningChanges[0].baseContentLength, 0)
    XCTAssertEqual(reasoningChanges[1].delta, " The tokenizer likely has the bug.")
    XCTAssertEqual(reasoningChanges[1].baseContentLength, 34)
    XCTAssertEqual(reasoningChanges[2].final, true)
    XCTAssertTrue(
      reasoningChanges[2].fullContent?.contains("The tokenizer likely has the bug.") == true)

    let toolChanges = changes.filter { $0.key == "tool:tool-read" }
    XCTAssertEqual(toolChanges[0].kind, .toolCall)
    XCTAssertEqual(toolChanges[0].toolName, "read")
    XCTAssertEqual(toolChanges[0].toolStatus, "inProgress")
    XCTAssertEqual(toolChanges[1].delta, "\nReading Sources/Tokenizer.swift")
    XCTAssertEqual(toolChanges[2].toolStatus, "completed")
    XCTAssertEqual(toolChanges[2].final, true)
    XCTAssertTrue(
      toolChanges[2].fullContent?.contains("Reading Sources/Tokenizer.swift") == true)

    let page = try await coordinator.conversationPage(taskID: task.id)
    let reasoning = page.first { $0.kind == .reasoning }
    XCTAssertNotNil(reasoning)
    XCTAssertTrue(
      reasoning?.content.contains("I should inspect the parser first.") == true)
    let tool = page.first { $0.kind == .toolCall }
    XCTAssertNotNil(tool)
    XCTAssertEqual(tool?.toolName, "read")
    XCTAssertEqual(tool?.toolStatus, "completed")
    XCTAssertEqual(tool?.toolArguments, #"{"path":"Sources/Tokenizer.swift"}"#)
    XCTAssertTrue(
      tool?.content.contains("Reading Sources/Tokenizer.swift") == true)

    await coordinator.unsubscribeConversation(
      taskID: task.id,
      subscriptionID: subscription.subscriptionID
    )
    collect.cancel()
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }
}

func agentDeltaScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-conversation", root: root)
  let turn = executionTurnJSON(id: "turn-conversation", status: "inProgress")
  let completed = executionTurnJSON(
    id: "turn-conversation",
    status: "completed",
    items:
      #"[{"id":"item-message","type":"agentMessage","text":"Final authoritative agent text."}]"#
  )
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-conversation","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-conversation","turnId":"turn-conversation","itemId":"item-message","delta":"I will fix"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-conversation","turnId":"turn-conversation","itemId":"item-message","delta":" the parser"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-conversation","turnId":"turn-conversation","itemId":"item-message","delta":" now."}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-conversation","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}

func failedTurnScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-failed", root: root)
  let turn = executionTurnJSON(id: "turn-failed", status: "inProgress")
  let failed =
    #"{"id":"turn-failed","status":"failed","error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"server_overloaded"},"items":[],"itemsView":"full","startedAt":1,"completedAt":null,"durationMs":null}"#
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-failed","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-failed","turn":__FAILED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__FAILED__", with: failed)
}

func richConversationScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-rich", root: root)
  let turn = executionTurnJSON(id: "turn-rich", status: "inProgress")
  let completedItems =
    #"["#
    + #"{"id":"reasoning-main","type":"reasoning","content":["I should inspect the parser first."," The tokenizer likely has the bug."],"summary":["Fix the tokenizer."]},"#
    + #"{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/Tokenizer.swift"},"status":"completed"},"#
    + #"{"id":"item-message","type":"agentMessage","text":"The tokenizer is fixed."}"#
    + #"]"#
  let completed = executionTurnJSON(id: "turn-rich", status: "completed", items: completedItems)
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-rich","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-rich","turnId":"turn-rich","startedAtMs":1,"item":{"id":"reasoning-main","type":"reasoning","content":[],"summary":[]}}}'
      printf '%s\n' '{"method":"item/reasoning/textDelta","params":{"threadId":"thread-rich","turnId":"turn-rich","itemId":"reasoning-main","contentIndex":0,"delta":"I should inspect the parser first."}}'
      printf '%s\n' '{"method":"item/reasoning/textDelta","params":{"threadId":"thread-rich","turnId":"turn-rich","itemId":"reasoning-main","contentIndex":0,"delta":" The tokenizer likely has the bug."}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-rich","turnId":"turn-rich","startedAtMs":2,"item":{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/Tokenizer.swift"},"status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/mcpToolCall/progress","params":{"threadId":"thread-rich","turnId":"turn-rich","itemId":"tool-read","message":"Reading Sources/Tokenizer.swift"}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-rich","turnId":"turn-rich","completedAtMs":3,"item":{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/Tokenizer.swift"},"status":"completed"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-rich","turnId":"turn-rich","itemId":"item-message","delta":"The tokenizer is fixed."}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-rich","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}

actor ChangeCollector {
  private var changes: [ConversationChange] = []

  func collect(_ stream: AsyncStream<ConversationChange>) async {
    for await change in stream {
      changes.append(change)
    }
  }

  func count() -> Int {
    changes.count
  }

  func count(key: String) -> Int {
    changes.count { $0.key == key }
  }

  func first() -> ConversationChange? {
    changes.first
  }

  func all() -> [ConversationChange] {
    changes
  }
}
