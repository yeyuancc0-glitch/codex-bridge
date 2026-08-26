import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class TaskConversationBufferTests: XCTestCase {
  func testUserMessageStreamsFullContentAndPersistsImmediately() async throws {
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
    XCTAssertEqual(persistedBeforeClose.map(\.key), [change?.key].compactMap { $0 })
    XCTAssertEqual(persistedBeforeClose[0].content, "Please add a test.")

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

  func testFinalAuthoritativeContentResynchronizesAfterSubscriberBufferDrops() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-dropped-deltas"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 256,
      flushInFlightCount: 256
    )
    let subscription = await buffer.subscribe(taskID: task.id)
    for index in 0..<96 {
      await buffer.appendDelta(
        taskID: task.id,
        itemID: "item-overflow",
        delta: "\(index),"
      )
    }
    let authoritative = "authoritative final response"
    await buffer.finalize(
      taskID: task.id,
      messages: [
        try ExecutionAgentMessage(
          key: "agent:item-overflow",
          role: .agent,
          content: authoritative
        )
      ]
    )

    var finalChange: ConversationChange?
    for await change in subscription.updates {
      if change.final {
        finalChange = change
        break
      }
    }
    XCTAssertEqual(finalChange?.fullContent, authoritative)
    XCTAssertEqual(finalChange?.baseContentLength, 0)
    _ = await buffer.close(taskID: task.id)
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

  func testPeriodicFlushPersistsSingleActivityWithoutWaitingForAnotherEvent() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-periodic-flush"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 64,
      flushInFlightCount: 64,
      flushIntervalNanoseconds: 20_000_000
    )

    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "working")

    try await waitUntil {
      let messages = try? await fixture.store.taskMessages(taskID: task.id)
      return messages?.first?.content == "working"
    }
    let inFlight = await buffer.inFlightCount(taskID: task.id)
    XCTAssertEqual(inFlight, 0)
    _ = await buffer.close(taskID: task.id)
  }

  func testCloseDoesNotRewriteCleanPersistedMessageTimestamp() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-close-timestamp"
    )
    let buffer = TaskConversationBuffer(tasks: fixture.tasks)
    await buffer.appendUserMessage(taskID: task.id, content: "Persist once.")
    let beforeMessages = try await fixture.store.taskMessages(taskID: task.id)
    let before = try XCTUnwrap(beforeMessages.first?.createdAt)

    try await Task.sleep(for: .milliseconds(20))
    let closed = await buffer.close(taskID: task.id)
    XCTAssertTrue(closed)

    let afterMessages = try await fixture.store.taskMessages(taskID: task.id)
    let after = try XCTUnwrap(afterMessages.first?.createdAt)
    XCTAssertEqual(after, before)
  }

  func testCloseRetainsConversationWhenFinalPersistenceFails() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-persistence-failure"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 64,
      flushInFlightCount: 64,
      closeFlushRetryCount: 2,
      closeFlushRetryDelayNanoseconds: 1_000_000,
      failedCloseRetentionNanoseconds: 20_000_000
    )
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "not persisted")
    _ = try await fixture.tasks.interrupt(taskID: task.id, summary: "test cleanup")
    try await fixture.tasks.remove(taskID: task.id)

    let closed = await buffer.close(taskID: task.id)

    XCTAssertFalse(closed)
    let retained = await buffer.entries(taskID: task.id)
    XCTAssertEqual(retained.map(\.content), ["not persisted"])
    XCTAssertEqual(retained.map(\.isFinal), [true])
    try await waitUntil {
      await buffer.entries(taskID: task.id).isEmpty
    }
  }

  func testFirstProviderEventKeepsCreationTimeAcrossDelayedInitialFlush() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-buffer-creation-time"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 64,
      flushInFlightCount: 64,
      flushIntervalNanoseconds: 10_000_000_000
    )

    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: "first")
    let initialEntries = await buffer.entries(taskID: task.id)
    let initial = try XCTUnwrap(initialEntries.first)
    try await Task.sleep(for: .milliseconds(20))
    await buffer.appendDelta(taskID: task.id, itemID: "item-1", delta: " second")
    let updatedEntries = await buffer.entries(taskID: task.id)
    let updated = try XCTUnwrap(updatedEntries.first)
    XCTAssertEqual(updated.createdAt, initial.createdAt)
    XCTAssertGreaterThan(updated.updatedAt, initial.updatedAt)

    let closed = await buffer.close(taskID: task.id)
    XCTAssertTrue(closed)
    let messages = try await fixture.store.taskMessages(taskID: task.id)
    let persisted = try XCTUnwrap(messages.first)
    XCTAssertEqual(
      persisted.createdAt.timeIntervalSince1970,
      initial.createdAt.timeIntervalSince1970,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      persisted.updatedAt.timeIntervalSince1970,
      updated.updatedAt.timeIntervalSince1970,
      accuracy: 0.000_001
    )
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

  func testPersistedFinalEntriesAreEvictedFromActiveMemoryWindow() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "task-eviction"
    )
    let buffer = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 1,
      flushInFlightCount: 1
    )

    let total = TaskConversationBuffer.maximumRetainedMessagesPerTask + 8
    for index in 0..<total {
      let call = try ExecutionToolCall(
        itemID: "tool-\(index)",
        tool: "read",
        arguments: "item-\(index)",
        status: .completed
      )
      await buffer.upsertToolCall(taskID: task.id, call: call)
    }

    let entries = await buffer.entries(taskID: task.id)
    XCTAssertEqual(entries.count, TaskConversationBuffer.maximumRetainedMessagesPerTask)
    XCTAssertEqual(entries.first?.key, "tool:tool-8")

    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.count, total)
    await buffer.close(taskID: task.id)
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
