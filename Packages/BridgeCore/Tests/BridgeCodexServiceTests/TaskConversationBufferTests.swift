import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class TaskConversationBufferTests: XCTestCase {
  func testUserMessageStreamsFullContentAndPersistsOnClose() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-user")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    XCTAssertEqual(subscription.page.count, 0)

    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    await buffer.appendUserMessage(taskID: task.id, content: "Please add a test.")

    try await waitUntil { await collector.count() == 1 }
    let change = await collector.first()
    XCTAssertEqual(change?.role, .user)
    XCTAssertEqual(change?.fullContent, "Please add a test.")
    XCTAssertEqual(change?.final, true)

    let persistedBeforeClose = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertTrue(persistedBeforeClose.isEmpty)

    await buffer.close(taskID: task.id)

    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.map(\.key), [change?.key].compactMap { $0 })
    XCTAssertEqual(persisted[0].content, "Please add a test.")
    collect.cancel()
  }

  func testDeltaLifecycleAccumulatesThenFinalizeReplacesWithAuthoritativeContent() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-delta")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "Hello")
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: " world")
    try await waitUntil { await collector.count() == 2 }

    var entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].key, "agent:item-1")
    XCTAssertEqual(entries[0].content, "Hello world")
    XCTAssertEqual(entries[0].isFinal, false)

    let updates = await collector.all()
    XCTAssertEqual(updates.count, 2)
    XCTAssertEqual(updates[0].fullContent, "Hello")
    XCTAssertEqual(updates[0].baseContentLength, 0)
    XCTAssertEqual(updates[1].delta, " world")
    XCTAssertEqual(updates[1].baseContentLength, 5)

    let finalMessage = try ExecutionAgentMessage(
      key: "agent:item-1",
      role: .agent,
      content: "Hello world, authoritative."
    )
    await buffer.finalize(taskID: task.id, messages: [finalMessage])

    entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries[0].content, "Hello world, authoritative.")
    XCTAssertEqual(entries[0].isFinal, true)

    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted[0].content, "Hello world, authoritative.")

    await buffer.close(taskID: task.id)
    collect.cancel()
  }

  func testSubscribePageIsAtomicSnapshotBeforeNewChanges() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-snapshot")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    await buffer.appendUserMessage(taskID: task.id, content: "seed")

    let subscription = await buffer.subscribe(taskID: task.id)
    XCTAssertEqual(subscription.page.count, 1)
    XCTAssertTrue(subscription.page[0].key.hasPrefix("user:"))
    XCTAssertEqual(subscription.page[0].content, "seed")

    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }
    await buffer.appendDelta(taskID: task.id, itemID: "item-2", delta: "after")
    try await waitUntil { await collector.count() == 1 }
    await buffer.close(taskID: task.id)
    collect.cancel()
  }

  func testUnsubscribeStopsDelivery() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-unsub")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "first")
    try await waitUntil { await collector.count() == 1 }

    await buffer.unsubscribe(taskID: task.id, subscriptionID: subscription.subscriptionID)
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: " second")

    try await Task.sleep(for: .milliseconds(100))
    let count = await collector.count()
    XCTAssertEqual(count, 1)
    await buffer.close(taskID: task.id)
    collect.cancel()
  }

  func testFlushThresholdPersistsWithoutWaitingForClose() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-flush")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 2)
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "a")
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "b")

    var inFlight = await buffer.inFlightCount(taskID: task.id)
    XCTAssertEqual(inFlight, 0)
    var persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.map(\.content), ["ab"])

    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "c")

    inFlight = await buffer.inFlightCount(taskID: task.id)
    XCTAssertEqual(inFlight, 1)
    persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.map(\.content), ["ab"])

    await buffer.close(taskID: task.id)

    persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.map(\.content), ["abc"])
  }

  func testPurgeStopsDeliveringChanges() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-purge")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "first")
    try await waitUntil { await collector.count() == 1 }

    await buffer.purge(taskID: task.id)
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: " second")

    try await Task.sleep(for: .milliseconds(100))
    let count = await collector.count()
    XCTAssertEqual(count, 1)
    collect.cancel()
  }

  func testSubscriberOverflowFinishesNewStream() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-overflow")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    for _ in 0..<TaskConversationBuffer.maximumSubscribersPerTask {
      _ = await buffer.subscribe(taskID: task.id)
    }
    let overflow = await buffer.subscribe(taskID: task.id)
    XCTAssertEqual(overflow.subscriptionID, -1)
    var iterator = overflow.updates.makeAsyncIterator()
    let next = await iterator.next()
    XCTAssertNil(next)
    await buffer.close(taskID: task.id)
  }

  func testReasoningDeltasAccumulateAndFinalizeAuthoritativeContent() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-reasoning"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    await buffer.appendDelta(
      taskID: task.id, itemID: "reasoning-1", delta: "I should inspect", kind: .reasoning)
    await buffer.appendDelta(
      taskID: task.id, itemID: "reasoning-1", delta: " the parser.", kind: .reasoning)

    var entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].key, "reasoning:reasoning-1")
    XCTAssertEqual(entries[0].kind, .reasoning)
    XCTAssertEqual(entries[0].content, "I should inspect the parser.")
    XCTAssertEqual(entries[0].isFinal, false)

    let finalMessage = try ExecutionAgentMessage(
      key: "reasoning:reasoning-1",
      role: .agent,
      kind: .reasoning,
      content: "I should inspect the parser.\nFix the tokenizer."
    )
    await buffer.finalize(taskID: task.id, messages: [finalMessage])

    entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries[0].content, "I should inspect the parser.\nFix the tokenizer.")
    XCTAssertEqual(entries[0].isFinal, true)

    try await waitUntil { await collector.count(key: "reasoning:reasoning-1") == 3 }
    let updates = await collector.all()
    XCTAssertEqual(updates[0].kind, .reasoning)
    XCTAssertEqual(updates[0].fullContent, "I should inspect")
    XCTAssertEqual(updates[1].delta, " the parser.")
    XCTAssertEqual(updates[2].kind, .reasoning)
    XCTAssertEqual(updates[2].final, true)
    XCTAssertEqual(
      updates[2].fullContent, "I should inspect the parser.\nFix the tokenizer.")

    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted[0].kind, .reasoning)
    XCTAssertEqual(persisted[0].content, "I should inspect the parser.\nFix the tokenizer.")
    await buffer.close(taskID: task.id)
    collect.cancel()
  }

  func testToolCallLifecycleStreamsStatusAndProgressAndPersists() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(fixture: fixture, taskID: "tsk-buffer-tool")
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks, flushDeltaCount: 8, flushInFlightCount: 4)
    let subscription = await buffer.subscribe(taskID: task.id)
    let collector = ChangeCollector()
    let collect = Task { await collector.collect(subscription.updates) }

    let started = try ExecutionToolCall(
      itemID: "tool-1", tool: "read", arguments: #"{"path":"Sources/A.swift"}"#,
      status: .inProgress)
    await buffer.upsertToolCall(taskID: task.id, call: started)

    var entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].key, "tool:tool-1")
    XCTAssertEqual(entries[0].kind, .toolCall)
    XCTAssertEqual(entries[0].toolName, "read")
    XCTAssertEqual(entries[0].toolStatus, "inProgress")
    XCTAssertEqual(entries[0].isFinal, false)

    await buffer.appendToolCallProgress(
      taskID: task.id, itemID: "tool-1", progress: "Reading Sources/A.swift")

    let completed = try ExecutionToolCall(
      itemID: "tool-1", tool: "read", arguments: #"{"path":"Sources/A.swift"}"#,
      status: .completed)
    await buffer.upsertToolCall(taskID: task.id, call: completed)

    entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries[0].toolStatus, "completed")
    XCTAssertEqual(entries[0].isFinal, true)
    XCTAssertEqual(
      entries[0].content, #"{"path":"Sources/A.swift"}"# + "\nReading Sources/A.swift")
    XCTAssertEqual(entries[0].toolArguments, #"{"path":"Sources/A.swift"}"#)

    try await waitUntil { await collector.count(key: "tool:tool-1") == 3 }
    let updates = await collector.all()
    let toolUpdates = updates.filter { $0.key == "tool:tool-1" }
    XCTAssertEqual(toolUpdates.count, 3)
    XCTAssertEqual(toolUpdates[0].kind, .toolCall)
    XCTAssertEqual(toolUpdates[0].toolStatus, "inProgress")
    XCTAssertEqual(toolUpdates[1].delta, "\nReading Sources/A.swift")
    XCTAssertEqual(toolUpdates[2].toolStatus, "completed")
    XCTAssertEqual(toolUpdates[2].final, true)

    await buffer.close(taskID: task.id)

    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted[0].kind, .toolCall)
    XCTAssertEqual(persisted[0].toolName, "read")
    XCTAssertEqual(persisted[0].toolStatus, "completed")
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
