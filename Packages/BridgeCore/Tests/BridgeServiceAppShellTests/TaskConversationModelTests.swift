import BridgeIPC
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class TaskConversationModelTests: XCTestCase {
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
}
