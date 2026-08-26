import BridgeDomain
import BridgeServiceCore
import Foundation

extension TaskConversationBuffer {

  public func appendUserMessage(taskID: TaskID, content: String) async {
    guard !content.isEmpty else { return }
    let state = state(taskID: taskID)
    guard state.entries.count < Self.maximumMessagesPerTask else { return }
    let key = "user:" + UUID().uuidString.lowercased()
    append(Entry(key: key, role: .user, kind: .user, content: content, isFinal: true), in: state)
    markDirty(taskID: taskID, key: key, in: state)
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
    markDirty(taskID: taskID, key: key, in: state)
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
    guard
      let change = mergeDelta(
        taskID: taskID,
        key: key,
        delta: delta,
        kind: kind,
        in: state
      )
    else { return }
    markDirty(taskID: taskID, key: key, in: state)
    notify(change, in: state)
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
    guard apply(entry, in: state) else { return }
    markDirty(taskID: taskID, key: key, in: state)
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
    guard
      let change = mergeToolCallProgress(
        taskID: taskID,
        key: key,
        progress: progress,
        in: state
      )
    else { return }
    markDirty(taskID: taskID, key: key, in: state)
    notify(change, in: state)
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

  /// Authoritative full-content upsert used by agent providers whose events
  /// carry complete snapshots instead of append-only deltas.
  public func upsertAuthoritativeEntry(
    taskID: TaskID,
    key: String,
    kind: ServiceTaskMessageKind,
    content: String,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    isFinal: Bool
  ) async {
    guard kind == .agent || kind == .reasoning || kind == .toolCall else { return }
    let cappedContent = Self.capped(content)
    guard !cappedContent.isEmpty else { return }
    let state = state(taskID: taskID)
    let entry = Entry(
      key: key,
      role: .agent,
      kind: kind,
      content: cappedContent,
      toolName: toolName.map(Self.cappedToolName),
      toolStatus: toolStatus,
      toolArguments: toolArguments,
      isFinal: isFinal
    )
    guard apply(entry, in: state) else { return }
    markDirty(taskID: taskID, key: key, in: state)
    notify(
      ConversationChange(
        taskID: taskID,
        key: key,
        role: .agent,
        kind: kind,
        delta: nil,
        baseContentLength: 0,
        fullContent: cappedContent,
        final: isFinal,
        toolName: entry.toolName,
        toolStatus: toolStatus,
        toolArguments: toolArguments
      ),
      in: state
    )
    if await shouldFlush(state) {
      _ = await flush(taskID: taskID)
    }
  }

  private func mergeDelta(
    taskID: TaskID,
    key: String,
    delta: String,
    kind: ServiceTaskMessageKind,
    in state: TaskState
  ) -> ConversationChange? {
    if let index = state.index[key], state.entries.indices.contains(index) {
      let entry = state.entries[index]
      guard !entry.isFinal, entry.content.utf8.count < Self.maximumMessageBytes else {
        return nil
      }
      let content = Self.cappedAppend(entry.content, delta)
      guard content != entry.content else { return nil }
      state.entries[index] = Entry(
        key: entry.key,
        role: .agent,
        kind: kind,
        content: content,
        isFinal: false,
        createdAt: entry.createdAt,
        updatedAt: Date()
      )
      return ConversationChange(
        taskID: taskID,
        key: entry.key,
        role: .agent,
        kind: kind,
        delta: delta,
        baseContentLength: entry.content.count,
        fullContent: nil,
        final: false
      )
    }

    guard state.entries.count < Self.maximumMessagesPerTask else { return nil }
    let content = Self.capped(delta)
    append(
      Entry(key: key, role: .agent, kind: kind, content: content, isFinal: false),
      in: state
    )
    return ConversationChange(
      taskID: taskID,
      key: key,
      role: .agent,
      kind: kind,
      delta: nil,
      baseContentLength: 0,
      fullContent: content,
      final: false
    )
  }

  private func mergeToolCallProgress(
    taskID: TaskID,
    key: String,
    progress: String,
    in state: TaskState
  ) -> ConversationChange? {
    guard let index = state.index[key], state.entries.indices.contains(index) else { return nil }
    let existing = state.entries[index]
    guard !existing.isFinal, existing.content.utf8.count < Self.maximumMessageBytes else {
      return nil
    }
    let line = existing.content.isEmpty ? progress : "\n" + progress
    let content = Self.cappedAppend(existing.content, line)
    guard content != existing.content else { return nil }
    state.entries[index] = Entry(
      key: key,
      role: .agent,
      kind: .toolCall,
      content: content,
      toolName: existing.toolName,
      toolStatus: existing.toolStatus,
      toolArguments: existing.toolArguments,
      isFinal: false,
      createdAt: existing.createdAt,
      updatedAt: Date()
    )
    return ConversationChange(
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
    )
  }

  private func append(_ entry: Entry, in state: TaskState) {
    state.index[entry.key] = state.entries.count
    state.entries.append(entry)
  }

  private func apply(_ entry: Entry, in state: TaskState) -> Bool {
    if let index = state.index[entry.key] {
      let existing = state.entries[index]
      guard !existing.isFinal else { return false }
      state.entries[index] = Entry(
        key: entry.key,
        role: entry.role,
        kind: entry.kind,
        content: entry.content,
        toolName: entry.toolName,
        toolStatus: entry.toolStatus,
        toolArguments: entry.toolArguments,
        isFinal: entry.isFinal,
        createdAt: existing.createdAt,
        updatedAt: entry.updatedAt
      )
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
    guard apply(entry, in: state) else { return false }
    markDirty(taskID: taskID, key: key, in: state)
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

  private static func cappedToolName(_ name: String) -> String {
    guard name.utf8.count > 256 else { return name }
    return String(decoding: name.utf8.prefix(256), as: UTF8.self)
  }

  private static func cappedAppend(_ content: String, _ delta: String) -> String {
    guard content.utf8.count + delta.utf8.count <= maximumMessageBytes else {
      return content
    }
    return content + delta
  }
}
