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
  private let projectRoot: String?
  private var sequence: Int64 = 0
  private var contentOrder: [String] = []
  private var contents: [String: ContentState] = [:]
  private var tools: [String: ToolState] = [:]
  private static let maximumContentBytes = 256 * 1_024
  private static let maximumContentStreams = 64
  private static let maximumTools = 256

  public init(taskID: TaskID, binding: AgentBinding, projectRoot: String? = nil) {
    self.taskID = taskID
    self.binding = binding
    self.projectRoot = projectRoot.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path
    }
  }

  public func normalize(_ event: OpenCodeACPClientEvent) throws -> AgentEventEnvelope? {
    switch event {
    case .permissionRequested(let request):
      try validateSession(request.sessionID)
      return try approval(request)
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
    let name = Self.semanticToolName(title: state.title, kind: state.kind)
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

  private static func semanticToolName(title: String?, kind: String?) -> String {
    let values = [title, kind].compactMap { normalizedWords($0) }
    let tokens = Set(values.flatMap { $0.split(separator: "_").map(String.init) })

    if tokens.contains("web") || tokens.contains("browser") || tokens.contains("internet") {
      if tokens.contains("search") || tokens.contains("query") || tokens.contains("lookup") {
        return "web_search"
      }
      if tokens.contains("fetch") || tokens.contains("read") || tokens.contains("open")
        || tokens.contains("url") || tokens.contains("page") || tokens.contains("content")
      {
        return "web_fetch"
      }
    }
    if tokens.contains("url") && (tokens.contains("read") || tokens.contains("fetch")) {
      return "web_fetch"
    }
    if tokens.contains("task") || tokens.contains("agent") || tokens.contains("subagent")
      || tokens.contains("delegate") || tokens.contains("explore")
    {
      return "subagent"
    }
    if values.contains("think") {
      // A real `think` tool is analysis, not evidence of a child run.
      return "think"
    }
    if values.contains(where: { ["search", "grep", "glob", "find"].contains($0) }) {
      return "search_files"
    }
    if values.contains(where: { ["read", "read_file"].contains($0) }) {
      return "read_files"
    }
    if values.contains(where: { ["list", "list_files", "list_directory"].contains($0) }) {
      return "list_files"
    }
    if values.contains(where: {
      ["edit", "write", "patch", "delete", "move", "file_change"].contains($0)
    }) {
      return "file_change"
    }
    if values.contains(where: { ["execute", "command", "bash", "shell", "exec"].contains($0) }) {
      return "command_execution"
    }
    return normalizedWords(kind) ?? normalizedWords(title) ?? "tool"
  }

  private static func normalizedWords(_ value: String?) -> String? {
    guard let value else { return nil }
    let bounded = String(decoding: value.utf8.prefix(192), as: UTF8.self)
    let normalized =
      bounded
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "_")
    return normalized.isEmpty ? nil : normalized
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

  private func approval(
    _ request: OpenCodeACPPermissionRequest
  ) throws -> AgentEventEnvelope {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeTitle = Self.safeText(title) ?? "OpenCode permission request"
    let input = request.rawInput?.objectValue ?? [:]
    let relativePaths = Self.relativePaths(from: input, projectRoot: projectRoot)
    let approval = try AgentApprovalRequest(
      approvalID: request.approvalID,
      taskID: taskID,
      binding: binding,
      providerItemID: request.toolCallID,
      kind: Self.approvalKind(request.kind),
      title: safeTitle,
      relativePaths: relativePaths,
      normalizedCommand: Self.safeCommand(input["command"]?.stringValue),
      networkTarget: Self.safeNetworkTarget(
        input["url"]?.stringValue
          ?? input["uri"]?.stringValue
          ?? input["target"]?.stringValue
      ),
      options: request.options
    )
    return try envelope(.approvalRequested(approval))
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

  private static func approvalKind(_ value: String?) -> AgentApprovalKind {
    switch value?.lowercased() {
    case "execute", "command", "bash", "shell":
      .command
    case "edit", "file", "file_change", "create", "delete", "move", "write":
      .fileChange
    case "network", "webfetch", "websearch", "fetch":
      .network
    case "read", "glob", "grep", "list", "lsp", "tool":
      .tool
    default:
      .unknown
    }
  }

  private static func safeText(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 8 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      !containsSensitiveMarker(value.lowercased())
    else { return nil }
    return value
  }

  private static func safeCommand(_ value: String?) -> String? {
    guard let value else { return nil }
    return safeText(value)
  }

  private static func relativePaths(
    from input: [String: ACPJSONValue],
    projectRoot: String?
  ) -> [String] {
    guard let projectRoot else { return [] }
    let keys = ["path", "filePath", "filepath", "file", "source", "destination"]
    let values = keys.compactMap { input[$0]?.stringValue }
    var paths = Set<String>()
    for value in values {
      guard let path = relativePath(value, projectRoot: projectRoot) else { continue }
      paths.insert(path)
    }
    return paths.sorted()
  }

  private static func relativePath(_ value: String, projectRoot: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    let relative: String
    if value.hasPrefix("/") {
      let absolute = URL(fileURLWithPath: value).standardizedFileURL.path
      guard absolute.hasPrefix(projectRoot + "/") else { return nil }
      relative = String(absolute.dropFirst(projectRoot.count + 1))
    } else {
      relative = value
    }
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !containsSensitiveMarker(relative.lowercased())
    else { return nil }
    return relative
  }

  private static func safeNetworkTarget(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 4 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      let url = URLComponents(string: value),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host != nil,
      !containsSensitiveMarker(value.lowercased())
    else { return nil }
    var sanitized = url
    sanitized.user = nil
    sanitized.password = nil
    sanitized.query = nil
    sanitized.fragment = nil
    guard let result = sanitized.string, result.utf8.count <= 4 * 1_024 else { return nil }
    return result
  }

  private static func containsSensitiveMarker(_ value: String) -> Bool {
    [
      "token", "secret", "password", "passwd", "api_key", "apikey", "authorization",
      "cookie", "private_key", ".env", ".ssh",
    ].contains { value.contains($0) }
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
