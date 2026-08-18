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

    try await coordinator.unsubscribeConversation(
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
