import BridgeDomain
import BridgeServiceCore
import Foundation

public struct ConversationChange: Sendable, Equatable {
  public let taskID: TaskID
  public let key: String
  public let role: ServiceTaskMessageRole
  public let kind: ServiceTaskMessageKind
  public let delta: String?
  public let baseContentLength: Int
  public let fullContent: String?
  public let final: Bool
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?

  public init(
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    kind: ServiceTaskMessageKind,
    delta: String?,
    baseContentLength: Int,
    fullContent: String?,
    final: Bool,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil
  ) {
    self.taskID = taskID
    self.key = key
    self.role = role
    self.kind = kind
    self.delta = delta
    self.baseContentLength = baseContentLength
    self.fullContent = fullContent
    self.final = final
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
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
    public let kind: ServiceTaskMessageKind
    public let content: String
    public let toolName: String?
    public let toolStatus: String?
    public let toolArguments: String?
    public let isFinal: Bool

    public init(
      key: String,
      role: ServiceTaskMessageRole,
      kind: ServiceTaskMessageKind = .agent,
      content: String,
      toolName: String? = nil,
      toolStatus: String? = nil,
      toolArguments: String? = nil,
      isFinal: Bool
    ) {
      self.key = key
      self.role = role
      self.kind = kind
      self.content = content
      self.toolName = toolName
      self.toolStatus = toolStatus
      self.toolArguments = toolArguments
      self.isFinal = isFinal
    }
  }

  public static let maximumMessageBytes = 256 * 1_024
  public static let maximumMessagesPerTask = 512
  public static let maximumRetainedMessagesPerTask = 64
  public static let maximumSubscribersPerTask = 8

  private final class TaskState {
    var entries: [Entry] = []
    var index: [String: Int] = [:]
    var dirtyRevisions: [String: Int] = [:]
    var persistedKeys: Set<String> = []
    var nextRevision = 0
    var unflushedCount: Int = 0
    var lastFlush: Date?
    var isFlushing = false
    var flushWaiters: [CheckedContinuation<Void, Never>] = []
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
    append(Entry(key: key, role: .user, kind: .user, content: content, isFinal: true), in: state)
    markDirty(key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .user,
        kind: .user,
        delta: nil,
        baseContentLength: 0,
        fullContent: content,
        final: true
      ),
      in: state
    )
    _ = await flush(taskID: taskID)
  }

  public func appendAgentMessage(taskID: TaskID, content: String) async {
    guard !content.isEmpty else { return }
    let state = state(taskID: taskID)
    guard state.entries.count < Self.maximumMessagesPerTask else { return }
    let key = "agent:bridge:" + UUID().uuidString.lowercased()
    append(Entry(key: key, role: .agent, kind: .agent, content: content, isFinal: true), in: state)
    markDirty(key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .agent,
        kind: .agent,
        delta: nil,
        baseContentLength: 0,
        fullContent: content,
        final: true
      ),
      in: state
    )
    _ = await flush(taskID: taskID)
  }

  public func appendDelta(
    taskID: TaskID,
    itemID: String,
    delta: String,
    kind: ServiceTaskMessageKind = .agent
  ) async {
    guard kind == .agent || kind == .reasoning else { return }
    guard !delta.isEmpty else { return }
    let state = state(taskID: taskID)
    let key = Self.keyPrefix(for: kind) + itemID
    if let entry = state.index[key].flatMap({
      state.entries.indices.contains($0) ? state.entries[$0] : nil
    }) {
      guard !entry.isFinal else { return }
      guard entry.content.utf8.count < Self.maximumMessageBytes else { return }
      let content = Self.cappedAppend(entry.content, delta)
      guard content != entry.content else { return }
      let baseContentLength = entry.content.count
      state.entries[state.index[key]!] = Entry(
        key: entry.key,
        role: .agent,
        kind: kind,
        content: content,
        isFinal: false
      )
      markDirty(key: key, in: state)
      notify(
        ConversationChange(
          taskID: taskID,
          key: entry.key,
          role: .agent,
          kind: kind,
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
      append(
        Entry(key: key, role: .agent, kind: kind, content: content, isFinal: false),
        in: state
      )
      markDirty(key: key, in: state)
      notify(
        ConversationChange(
          taskID: taskID,
          key: key,
          role: .agent,
          kind: kind,
          delta: nil,
          baseContentLength: 0,
          fullContent: content,
          final: false
        ),
        in: state
      )
    }
    if await shouldFlush(state) {
      _ = await flush(taskID: taskID)
    }
  }

  public func upsertToolCall(taskID: TaskID, call: ExecutionToolCall) async {
    let state = state(taskID: taskID)
    let key = "tool:" + call.itemID
    let isFinal = call.status != .inProgress
    let content: String
    if let index = state.index[key],
      state.entries.indices.contains(index),
      !state.entries[index].content.isEmpty
    {
      content = state.entries[index].content
    } else {
      content = Self.capped(Self.toolCallContent(call.arguments, toolName: call.tool))
    }
    let entry = Entry(
      key: key,
      role: .agent,
      kind: .toolCall,
      content: content,
      toolName: call.tool,
      toolStatus: call.status.rawValue,
      toolArguments: call.arguments,
      isFinal: isFinal
    )
    guard apply(entry, taskID: taskID, in: state) else { return }
    markDirty(key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .agent,
        kind: .toolCall,
        delta: nil,
        baseContentLength: 0,
        fullContent: content,
        final: isFinal,
        toolName: call.tool,
        toolStatus: call.status.rawValue,
        toolArguments: call.arguments
      ),
      in: state
    )
    if await shouldFlush(state) {
      _ = await flush(taskID: taskID)
    }
  }

  public func appendToolCallProgress(taskID: TaskID, itemID: String, progress: String) async {
    guard !progress.isEmpty else { return }
    let state = state(taskID: taskID)
    let key = "tool:" + itemID
    guard let index = state.index[key], state.entries.indices.contains(index) else { return }
    let existing = state.entries[index]
    guard !existing.isFinal else { return }
    guard existing.content.utf8.count < Self.maximumMessageBytes else { return }
    let line = existing.content.isEmpty ? progress : "\n" + progress
    let content = Self.cappedAppend(existing.content, line)
    guard content != existing.content else { return }
    let entry = Entry(
      key: key,
      role: .agent,
      kind: .toolCall,
      content: content,
      toolName: existing.toolName,
      toolStatus: existing.toolStatus,
      toolArguments: existing.toolArguments,
      isFinal: false
    )
    state.entries[index] = entry
    markDirty(key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .agent,
        kind: .toolCall,
        delta: line,
        baseContentLength: existing.content.count,
        fullContent: nil,
        final: false,
        toolName: existing.toolName,
        toolStatus: existing.toolStatus,
        toolArguments: existing.toolArguments
      ),
      in: state
    )
    if await shouldFlush(state) {
      _ = await flush(taskID: taskID)
    }
  }

  public func finalize(taskID: TaskID, messages: [ExecutionAgentMessage]) async {
    guard !messages.isEmpty else { return }
    let state = state(taskID: taskID)
    var didUpdate = false
    for message in messages where message.role == .agent {
      if finalizeOne(message, taskID: taskID, in: state) {
        didUpdate = true
      }
    }
    if didUpdate {
      _ = await flush(taskID: taskID)
    }
  }

  @discardableResult
  public func close(taskID: TaskID) async -> Bool {
    guard let state = states[taskID] else { return true }
    for (index, entry) in state.entries.enumerated() where !entry.isFinal {
      state.entries[index] = Entry(
        key: entry.key,
        role: entry.role,
        kind: entry.kind,
        content: entry.content,
        toolName: entry.toolName,
        toolStatus: entry.toolStatus,
        toolArguments: entry.toolArguments,
        isFinal: true
      )
      notify(
        ConversationChange(
          taskID: taskID,
          key: entry.key,
          role: entry.role,
          kind: entry.kind,
          delta: nil,
          baseContentLength: 0,
          fullContent: entry.content,
          final: true,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments
        ),
        in: state
      )
    }
    guard await flush(taskID: taskID, force: true) else { return false }
    states.removeValue(forKey: taskID)
    finishStreams(in: state)
    return true
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

  @discardableResult
  public func closeAll() async -> [TaskID] {
    let taskIDs = Array(states.keys)
    var failed: [TaskID] = []
    for taskID in taskIDs {
      if !(await close(taskID: taskID)) {
        failed.append(taskID)
      }
    }
    return failed
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

  private func apply(_ entry: Entry, taskID: TaskID, in state: TaskState) -> Bool {
    if let index = state.index[entry.key] {
      guard !state.entries[index].isFinal else { return false }
      state.entries[index] = entry
      return true
    }
    guard state.entries.count < Self.maximumMessagesPerTask else { return false }
    append(entry, in: state)
    return true
  }

  private func finalizeOne(
    _ message: ExecutionAgentMessage,
    taskID: TaskID,
    in state: TaskState
  ) -> Bool {
    let kind = message.kind
    guard kind == .agent || kind == .reasoning || kind == .toolCall else { return false }
    let key = message.key
    guard key.hasPrefix(Self.keyPrefix(for: kind)) else { return false }
    var content = Self.capped(message.content)
    if kind == .toolCall {
      content = Self.capped(Self.toolCallContent(content, toolName: message.toolName))
    }
    guard !content.isEmpty else { return false }
    let entry = Entry(
      key: key,
      role: .agent,
      kind: kind,
      content: content,
      toolName: message.toolName,
      toolStatus: message.toolStatus,
      toolArguments: message.toolArguments,
      isFinal: true
    )
    guard apply(entry, taskID: taskID, in: state) else { return false }
    markDirty(key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .agent,
        kind: kind,
        delta: nil,
        baseContentLength: 0,
        fullContent: content,
        final: true,
        toolName: message.toolName,
        toolStatus: message.toolStatus,
        toolArguments: message.toolArguments
      ),
      in: state
    )
    return true
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
    if state.unflushedCount >= flushDeltaCount { return true }
    if state.unflushedCount >= flushInFlightCount { return true }
    if let lastFlush = state.lastFlush {
      let interval = Double(flushIntervalNanoseconds) / 1_000_000_000
      return Date().timeIntervalSince(lastFlush) >= interval
    }
    return false
  }

  private func flush(taskID: TaskID, force: Bool = false) async -> Bool {
    guard let state = states[taskID] else { return true }
    while state.isFlushing {
      await withCheckedContinuation { continuation in
        state.flushWaiters.append(continuation)
      }
      guard states[taskID] === state else { return true }
    }
    let revisions = state.dirtyRevisions
    let snapshot: [(Entry, Int?)]
    if force {
      snapshot = state.entries.map { ($0, revisions[$0.key]) }
    } else {
      snapshot = state.entries.compactMap { entry in
        guard let revision = revisions[entry.key] else { return nil }
        return (entry, Optional(revision))
      }
    }
    guard !snapshot.isEmpty else { return true }

    state.isFlushing = true
    let flushedDeltaCount = state.unflushedCount
    var persisted: [(String, Int?)] = []
    for (entry, revision) in snapshot {
      do {
        try await tasks.upsertTaskMessage(
          taskID: taskID,
          key: entry.key,
          role: entry.role,
          content: entry.content,
          kind: entry.kind,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments
        )
        persisted.append((entry.key, revision))
      } catch {
        continue
      }
    }

    for (key, revision) in persisted {
      state.persistedKeys.insert(key)
      guard let revision, state.dirtyRevisions[key] == revision else { continue }
      state.dirtyRevisions.removeValue(forKey: key)
    }
    state.unflushedCount = max(
      state.dirtyRevisions.count,
      state.unflushedCount - flushedDeltaCount
    )
    state.lastFlush = Date()
    state.isFlushing = false
    if !force {
      prunePersistedFinalEntries(in: state)
    }
    let waiters = state.flushWaiters
    state.flushWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
    return persisted.count == snapshot.count
  }

  private func markDirty(key: String, in state: TaskState) {
    state.nextRevision &+= 1
    state.dirtyRevisions[key] = state.nextRevision
    state.unflushedCount += 1
  }

  private func prunePersistedFinalEntries(in state: TaskState) {
    var excess = state.entries.count - Self.maximumRetainedMessagesPerTask
    guard excess > 0 else { return }
    var retained: [Entry] = []
    retained.reserveCapacity(state.entries.count - excess)
    for entry in state.entries {
      let canEvict =
        excess > 0
        && entry.isFinal
        && state.persistedKeys.contains(entry.key)
        && state.dirtyRevisions[entry.key] == nil
      if canEvict {
        excess -= 1
        state.persistedKeys.remove(entry.key)
      } else {
        retained.append(entry)
      }
    }
    guard retained.count != state.entries.count else { return }
    state.entries = retained
    rebuildIndex(in: state)
  }

  private func rebuildIndex(in state: TaskState) {
    state.index.removeAll(keepingCapacity: true)
    for (position, entry) in state.entries.enumerated() {
      state.index[entry.key] = position
    }
  }

  private static func keyPrefix(for kind: ServiceTaskMessageKind) -> String {
    switch kind {
    case .user: "user:"
    case .agent: "agent:"
    case .reasoning: "reasoning:"
    case .toolCall: "tool:"
    }
  }

  private static func toolCallContent(_ arguments: String?, toolName: String?) -> String {
    if let arguments, !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return arguments
    }
    if let toolName, !toolName.isEmpty {
      return toolName
    }
    return "工具调用"
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
