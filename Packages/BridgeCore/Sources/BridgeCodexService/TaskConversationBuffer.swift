import BridgeDomain
import BridgeServiceCore
import Foundation

public struct ConversationChange: Sendable, Equatable {
  public let taskID: TaskID
  public let key: String
  public let role: ServiceTaskMessageRole
  public let delta: String?
  public let baseContentLength: Int
  public let fullContent: String?
  public let final: Bool

  public init(
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    delta: String?,
    baseContentLength: Int,
    fullContent: String?,
    final: Bool
  ) {
    self.taskID = taskID
    self.key = key
    self.role = role
    self.delta = delta
    self.baseContentLength = baseContentLength
    self.fullContent = fullContent
    self.final = final
  }
}

public struct ConversationSubscription: Sendable {
  public let subscriptionID: Int
  public let page: [TaskConversationBuffer.Entry]
  public let updates: AsyncStream<ConversationChange>

  public init(
    subscriptionID: Int,
    page: [TaskConversationBuffer.Entry],
    updates: AsyncStream<ConversationChange>
  ) {
    self.subscriptionID = subscriptionID
    self.page = page
    self.updates = updates
  }
}

public actor TaskConversationBuffer {
  public struct Entry: Sendable, Equatable {
    public let key: String
    public let role: ServiceTaskMessageRole
    public let content: String
    public let isFinal: Bool
  }

  public static let maximumMessageBytes = 256 * 1_024
  public static let maximumMessagesPerTask = 512
  public static let maximumSubscribersPerTask = 8

  private final class TaskState {
    var entries: [Entry] = []
    var index: [String: Int] = [:]
    var unflushedCount: Int = 0
    var lastFlush: Date?
    var isFlushing = false
    var subscribers: [Int: AsyncStream<ConversationChange>.Continuation] = [:]
    var nextSubscriberID = 0
  }

  private let tasks: ServiceTaskManager
  private let flushDeltaCount: Int
  private let flushInFlightCount: Int
  private let flushIntervalNanoseconds: UInt64
  private var states: [TaskID: TaskState] = [:]

  public init(
    tasks: ServiceTaskManager,
    flushDeltaCount: Int = 64,
    flushInFlightCount: Int = 8,
    flushIntervalNanoseconds: UInt64 = 1_000_000_000
  ) {
    self.tasks = tasks
    self.flushDeltaCount = max(1, flushDeltaCount)
    self.flushInFlightCount = max(1, flushInFlightCount)
    self.flushIntervalNanoseconds = max(1, flushIntervalNanoseconds)
  }

  public func appendUserMessage(taskID: TaskID, content: String) async {
    guard !content.isEmpty else { return }
    let state = state(taskID: taskID)
    guard state.entries.count < Self.maximumMessagesPerTask else { return }
    let key = "user:" + UUID().uuidString.lowercased()
    append(Entry(key: key, role: .user, content: content, isFinal: true), in: state)
    await flush(taskID: taskID)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .user,
        delta: nil,
        baseContentLength: 0,
        fullContent: content,
        final: true
      ),
      in: state
    )
  }

  public func appendDelta(taskID: TaskID, itemID: String, delta: String) async {
    guard !delta.isEmpty else { return }
    let state = state(taskID: taskID)
    let key = "agent:" + itemID
    if let entry = state.index[key].flatMap({ state.entries.indices.contains($0) ? state.entries[$0] : nil }) {
      guard !entry.isFinal else { return }
      guard entry.content.utf8.count < Self.maximumMessageBytes else { return }
      let content = Self.cappedAppend(entry.content, delta)
      guard content != entry.content else { return }
      let baseContentLength = entry.content.count
      state.entries[state.index[key]!] = Entry(
        key: entry.key,
        role: .agent,
        content: content,
        isFinal: false
      )
      state.unflushedCount += 1
      notify(
        ConversationChange(
          taskID: taskID,
          key: entry.key,
          role: .agent,
          delta: delta,
          baseContentLength: baseContentLength,
          fullContent: nil,
          final: false
        ),
        in: state
      )
    } else {
      guard state.entries.count < Self.maximumMessagesPerTask else { return }
      let content = Self.capped(delta)
      append(Entry(key: key, role: .agent, content: content, isFinal: false), in: state)
      state.unflushedCount += 1
      notify(
        ConversationChange(
          taskID: taskID,
          key: key,
          role: .agent,
          delta: nil,
          baseContentLength: 0,
          fullContent: content,
          final: false
        ),
        in: state
      )
    }
    if await shouldFlush(state) {
      await flush(taskID: taskID)
    }
  }

  public func finalize(taskID: TaskID, messages: [ExecutionAgentMessage]) async {
    guard !messages.isEmpty else { return }
    let state = state(taskID: taskID)
    var didUpdate = false
    for message in messages where message.role == .agent {
      let key = message.key
      guard key.hasPrefix("agent:") else { continue }
      let content = Self.capped(message.content)
      if let index = state.index[key] {
        let existing = state.entries[index]
        if existing.isFinal { continue }
        state.entries[index] = Entry(key: key, role: .agent, content: content, isFinal: true)
      } else {
        guard state.entries.count < Self.maximumMessagesPerTask else { continue }
        append(Entry(key: key, role: .agent, content: content, isFinal: true), in: state)
      }
      didUpdate = true
      notify(
        ConversationChange(
          taskID: taskID,
          key: key,
          role: .agent,
          delta: nil,
          baseContentLength: 0,
          fullContent: content,
          final: true
        ),
        in: state
      )
    }
    if didUpdate {
      await flush(taskID: taskID, force: true)
    }
  }

  public func close(taskID: TaskID) async {
    guard let state = states[taskID] else { return }
    for (index, entry) in state.entries.enumerated() where !entry.isFinal {
      state.entries[index] = Entry(
        key: entry.key,
        role: entry.role,
        content: entry.content,
        isFinal: true
      )
      notify(
        ConversationChange(
          taskID: taskID,
          key: entry.key,
          role: entry.role,
          delta: nil,
          baseContentLength: 0,
          fullContent: entry.content,
          final: true
        ),
        in: state
      )
    }
    await flush(taskID: taskID, force: true)
    states.removeValue(forKey: taskID)
    finishStreams(in: state)
  }

  public func purge(taskID: TaskID) async {
    guard let state = states.removeValue(forKey: taskID) else { return }
    finishStreams(in: state)
  }

  public func subscribe(taskID: TaskID) async -> ConversationSubscription {
    let state = state(taskID: taskID)
    var continuation: AsyncStream<ConversationChange>.Continuation!
    let stream = AsyncStream<ConversationChange>(
      bufferingPolicy: .bufferingNewest(64)
    ) { continuation = $0 }
    let subscriptionID: Int
    if state.subscribers.count < Self.maximumSubscribersPerTask {
      subscriptionID = state.nextSubscriberID
      state.subscribers[subscriptionID] = continuation
      state.nextSubscriberID += 1
    } else {
      subscriptionID = -1
      continuation.finish()
    }
    return ConversationSubscription(
      subscriptionID: subscriptionID,
      page: state.entries,
      updates: stream
    )
  }

  public func unsubscribe(taskID: TaskID, subscriptionID: Int) async {
    guard subscriptionID >= 0, let state = states[taskID] else { return }
    state.subscribers.removeValue(forKey: subscriptionID)
  }

  public func inFlightCount(taskID: TaskID) async -> Int {
    guard let state = states[taskID] else { return 0 }
    return state.unflushedCount
  }

  public func entries(taskID: TaskID) async -> [Entry] {
    guard let state = states[taskID] else { return [] }
    return state.entries
  }

  public func closeAll() async {
    let taskIDs = Array(states.keys)
    for taskID in taskIDs {
      await close(taskID: taskID)
    }
  }

  private func state(taskID: TaskID) -> TaskState {
    if let state = states[taskID] {
      return state
    }
    let state = TaskState()
    states[taskID] = state
    return state
  }

  private func append(_ entry: Entry, in state: TaskState) {
    state.index[entry.key] = state.entries.count
    state.entries.append(entry)
  }

  private func notify(_ change: ConversationChange, in state: TaskState) {
    for subscriber in state.subscribers.values {
      switch subscriber.yield(change) {
      case .enqueued, .dropped, .terminated:
        continue
      @unknown default:
        continue
      }
    }
  }

  private func finishStreams(in state: TaskState) {
    for subscriber in state.subscribers.values {
      subscriber.finish()
    }
  }

  private func shouldFlush(_ state: TaskState) async -> Bool {
    if state.isFlushing { return false }
    if state.unflushedCount >= flushDeltaCount { return true }
    if state.unflushedCount >= flushInFlightCount { return true }
    if let lastFlush = state.lastFlush {
      let interval = Double(flushIntervalNanoseconds) / 1_000_000_000
      return Date().timeIntervalSince(lastFlush) >= interval
    }
    return false
  }

  private func flush(taskID: TaskID, force: Bool = false) async {
    guard let state = states[taskID], !state.isFlushing else { return }
    guard force || state.unflushedCount > 0 else { return }
    state.isFlushing = true
    let snapshot = state.entries
    for entry in snapshot {
      try? await tasks.upsertTaskMessage(
        taskID: taskID,
        key: entry.key,
        role: entry.role,
        content: entry.content
      )
    }
    state.unflushedCount = 0
    state.lastFlush = Date()
    state.isFlushing = false
  }

  private static func capped(_ content: String) -> String {
    guard content.utf8.count > maximumMessageBytes else { return content }
    return String(decoding: content.utf8.prefix(maximumMessageBytes), as: UTF8.self)
  }

  private static func cappedAppend(_ content: String, _ delta: String) -> String {
    guard content.utf8.count + delta.utf8.count <= maximumMessageBytes else {
      return content
    }
    return content + delta
  }
}