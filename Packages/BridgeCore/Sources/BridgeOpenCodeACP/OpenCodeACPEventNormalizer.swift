import BridgeAgentCore
import BridgeDomain
import Foundation

public actor OpenCodeACPEventNormalizer {
  private struct ContentState: Sendable {
    let role: AgentContentRole
    let kind: AgentContentKind
    var content: String
  }

  private struct ToolState: Sendable {
    var title: String?
    var kind: String?
    var arguments: String?
    var output: String?
    var locations: [String] = []
    var status: AgentToolStatus = .pending
  }

  private let taskID: TaskID
  private let binding: AgentBinding
  private var sequence: Int64 = 0
  private var contentOrder: [String] = []
  private var contents: [String: ContentState] = [:]
  private var tools: [String: ToolState] = [:]
  private static let maximumContentBytes = 256 * 1_024
  private static let maximumContentStreams = 64
  private static let maximumTools = 256

  public init(taskID: TaskID, binding: AgentBinding) {
    self.taskID = taskID
    self.binding = binding
  }

  public func normalize(_ event: OpenCodeACPClientEvent) throws -> AgentEventEnvelope? {
    switch event {
    case .permissionDenied(let request):
      try validateSession(request.sessionID)
      return try envelope(.approvalAutomaticallyDenied(request.toolCallID))
    case .notification(let notification):
      return try normalize(notification)
    }
  }

  public func completed(stopReason: String, summary: String? = nil) throws -> AgentEventEnvelope {
    let resolvedSummary = summary ?? latestAssistantSummary() ?? "OpenCode turn completed."
    return try envelope(.completed(summary: resolvedSummary, stopReason: stopReason))
  }

  public func finalizeContent() throws -> [AgentEventEnvelope] {
    try contentOrder.compactMap { key in
      guard let state = contents[key], state.role == .assistant, !state.content.isEmpty else {
        return nil
      }
      let update = try AgentContentUpdate(
        key: key,
        role: state.role,
        kind: state.kind,
        mode: .full,
        content: state.content,
        baseContentLength: nil,
        isFinal: true,
        authoritative: true
      )
      return try envelope(.content(update))
    }
  }

  public func failed(code: String, summary: String) throws -> AgentEventEnvelope {
    try envelope(.failed(code: code, summary: summary))
  }

  public func interrupted() throws -> AgentEventEnvelope {
    try envelope(.interrupted)
  }

  private func normalize(_ notification: OpenCodeACPNotification) throws -> AgentEventEnvelope? {
    guard notification.method == "session/update" else { return nil }
    guard let params = notification.params?.objectValue,
      let sessionID = params["sessionId"]?.stringValue,
      let update = params["update"]?.objectValue,
      let updateType = update["sessionUpdate"]?.stringValue
    else {
      throw OpenCodeACPError.invalidMessage
    }
    try validateSession(sessionID)

    switch updateType {
    case "agent_message_chunk":
      return try content(update, role: .assistant, kind: .message, fallbackKey: "message:assistant")
    case "user_message_chunk":
      return try content(update, role: .user, kind: .message, fallbackKey: "message:user")
    case "agent_thought_chunk":
      return try content(
        update, role: .assistant, kind: .reasoning, fallbackKey: "reasoning:assistant")
    case "tool_call", "tool_call_update":
      return try tool(update)
    case "plan":
      return try plan(update)
    case "usage_update":
      return try usage(update)
    default:
      return nil
    }
  }

  private func content(
    _ update: [String: ACPJSONValue],
    role: AgentContentRole,
    kind: AgentContentKind,
    fallbackKey: String
  ) throws -> AgentEventEnvelope? {
    guard let content = update["content"]?.objectValue,
      content["type"]?.stringValue == "text",
      let text = content["text"]?.stringValue,
      !text.isEmpty
    else { return nil }
    let rawMessageID = update["messageId"]?.stringValue
    let key = rawMessageID.map { "\(fallbackKey):\($0)" } ?? fallbackKey
    let existing = contents[key]
    if let existing, existing.role != role || existing.kind != kind {
      throw OpenCodeACPError.invalidMessage
    }
    if existing == nil, contents.count >= Self.maximumContentStreams {
      throw OpenCodeACPError.oversizedFrame
    }
    let base = existing?.content.count ?? 0
    let combined = (existing?.content ?? "") + text
    guard combined.utf8.count <= Self.maximumContentBytes else {
      throw OpenCodeACPError.oversizedFrame
    }
    let payload = try AgentContentUpdate(
      key: key,
      role: role,
      kind: kind,
      mode: .delta,
      content: text,
      baseContentLength: base,
      isFinal: false,
      authoritative: false
    )
    if existing == nil { contentOrder.append(key) }
    contents[key] = ContentState(role: role, kind: kind, content: combined)
    return try envelope(.content(payload))
  }

  private func tool(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let toolCallID = update["toolCallId"]?.stringValue, !toolCallID.isEmpty else {
      throw OpenCodeACPError.invalidMessage
    }
    if tools[toolCallID] == nil, tools.count >= Self.maximumTools {
      throw OpenCodeACPError.oversizedFrame
    }
    var state = tools[toolCallID] ?? ToolState()
    if let title = update["title"]?.stringValue { state.title = title }
    if let kind = update["kind"]?.stringValue { state.kind = kind }
    if let status = update["status"]?.stringValue,
      let normalizedStatus = Self.toolStatus(status)
    {
      state.status = normalizedStatus
    }
    if let rawInput = update["rawInput"] {
      state.arguments = rawInput.encodedString()
    }
    if let output = Self.toolOutput(update["content"]) {
      state.output = output
    }
    if let locations = update["locations"]?.arrayValue {
      guard locations.count <= 128 else { throw OpenCodeACPError.oversizedFrame }
      state.locations = locations.compactMap { value in
        guard let path = value["path"]?.stringValue, path.hasPrefix("/") else { return nil }
        return path
      }
    }
    let name = state.kind ?? "tool"
    let payload = try AgentToolUpdate(
      key: "tool:\(toolCallID)",
      name: name,
      title: state.title,
      kind: state.kind,
      status: state.status,
      arguments: state.arguments,
      output: state.output,
      locations: state.locations
    )
    tools[toolCallID] = state
    return try envelope(.tool(payload))
  }

  private func plan(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let rawEntries = update["entries"]?.arrayValue else { return nil }
    guard rawEntries.count <= 64 else { throw OpenCodeACPError.oversizedFrame }
    let entries = try rawEntries.compactMap { value -> AgentPlanEntry? in
      guard let object = value.objectValue,
        let content = object["content"]?.stringValue,
        !content.isEmpty
      else { return nil }
      return try AgentPlanEntry(
        content: content,
        priority: object["priority"]?.stringValue,
        status: object["status"]?.stringValue
      )
    }
    return entries.isEmpty ? nil : try envelope(.plan(entries))
  }

  private func usage(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let used = update["used"]?.intValue,
      let size = update["size"]?.intValue
    else { return nil }
    let cost = update["cost"]?.objectValue
    let payload = try AgentUsageUpdate(
      usedTokens: used,
      contextSize: size,
      costAmount: cost?["amount"]?.doubleValue,
      currency: cost?["currency"]?.stringValue
    )
    return try envelope(.usage(payload))
  }

  private func validateSession(_ sessionID: String) throws {
    guard binding.providerSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }

  private func latestAssistantSummary() -> String? {
    for key in contentOrder.reversed() {
      guard let state = contents[key], state.role == .assistant else { continue }
      let trimmed = state.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      return String(decoding: trimmed.utf8.prefix(4 * 1_024), as: UTF8.self)
    }
    return nil
  }

  private func envelope(_ event: AgentEvent) throws -> AgentEventEnvelope {
    let current = sequence
    sequence += 1
    return try AgentEventEnvelope(
      taskID: taskID,
      providerID: binding.providerID,
      providerSessionID: binding.providerSessionID,
      providerRunID: binding.providerRunID,
      providerSequence: current,
      event: event
    )
  }

  private static func toolStatus(_ value: String) -> AgentToolStatus? {
    switch value {
    case "pending": .pending
    case "in_progress": .inProgress
    case "completed": .completed
    case "failed": .failed
    case "cancelled": .cancelled
    case "declined": .declined
    default: nil
    }
  }

  private static func toolOutput(_ value: ACPJSONValue?) -> String? {
    guard let items = value?.arrayValue else { return nil }
    let lines = items.compactMap { item -> String? in
      guard let object = item.objectValue, let type = object["type"]?.stringValue else {
        return nil
      }
      if type == "content",
        let content = object["content"]?.objectValue,
        content["type"]?.stringValue == "text"
      {
        return content["text"]?.stringValue
      }
      if type == "diff", let path = object["path"]?.stringValue {
        return "Diff: \(path)"
      }
      return nil
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
