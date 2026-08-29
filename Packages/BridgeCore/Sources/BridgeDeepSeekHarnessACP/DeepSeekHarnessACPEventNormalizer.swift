import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation

public actor DeepSeekHarnessACPEventNormalizer {
  private struct ToolState {
    var title: String?
    var kind: String?
    var status: AgentToolStatus = .pending
    var arguments: String?
  }

  private let taskID: TaskID
  private let binding: AgentBinding
  private let projectRoot: String?
  private var content = ""
  private var lastFinalizedContent = ""
  private var assistantMessageIndex: UInt64 = 0
  private var nextProviderSequence: Int64 = 0
  private var tools: [String: ToolState] = [:]

  private static let maximumAssistantMessageIndex: UInt64 = 1_000_000
  private static let maximumTools = 1_024

  public init(taskID: TaskID, binding: AgentBinding, projectRoot: String? = nil) {
    self.taskID = taskID
    self.binding = binding
    self.projectRoot = projectRoot.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path
    }
  }

  public func normalize(
    _ clientEnvelope: DeepSeekHarnessACPClientEventEnvelope
  ) throws -> AgentEventEnvelope? {
    switch clientEnvelope.event {
    case .textDelta(let sessionID, let text):
      try validateSession(sessionID)
      guard !text.isEmpty else { return nil }
      let baseLength = content.utf8.count
      let (next, overflow) = content.utf8.count.addingReportingOverflow(text.utf8.count)
      guard !overflow, next <= DeepSeekHarnessACPConstants.maximumFinalTextBytes else {
        throw DeepSeekHarnessACPError.oversizedFrame
      }
      content.append(text)
      let update = try AgentContentUpdate(
        key: assistantMessageKey,
        role: .assistant,
        kind: .message,
        mode: .delta,
        content: text,
        baseContentLength: baseLength,
        isFinal: false,
        authoritative: false
      )
      return try envelope(.content(update))
    case .toolUpdated(let update):
      try validateSession(update.sessionID)
      return try tool(update)
    case .permissionRequested(let request):
      try validateSession(request.sessionID)
      return try approval(request)
    case .approvalAutomaticallyDenied(let sessionID, let toolCallID):
      try validateSession(sessionID)
      try validateIdentifier(toolCallID, field: "permission.toolCallID")
      return try envelope(.approvalAutomaticallyDenied(toolCallID))
    }
  }

  func toolEvidence() -> (calls: Int, failedCalls: Int, unfinishedCalls: Int) {
    let failed = tools.values.reduce(0) { $0 + ($1.status == .failed ? 1 : 0) }
    let unfinished = tools.values.reduce(0) {
      $0 + ($1.status == .pending || $1.status == .inProgress ? 1 : 0)
    }
    return (tools.count, failed, unfinished)
  }

  public func finalizeContent() throws -> [AgentEventEnvelope] {
    guard let event = try finalizeCurrentContent() else { return [] }
    return [event]
  }

  func finalizeCurrentContent() throws -> AgentEventEnvelope? {
    guard !content.isEmpty else { return nil }
    guard assistantMessageIndex < Self.maximumAssistantMessageIndex else {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    let update = try AgentContentUpdate(
      key: assistantMessageKey,
      role: .assistant,
      kind: .message,
      mode: .full,
      content: content,
      baseContentLength: nil,
      isFinal: true,
      authoritative: true
    )
    lastFinalizedContent = content
    content = ""
    assistantMessageIndex += 1
    return try envelope(.content(update))
  }

  public func completed(stopReason: String) throws -> AgentEventEnvelope {
    let summary =
      lastFinalizedContent.isEmpty
      ? (content.isEmpty ? "DeepSeek Harness turn completed." : content)
      : lastFinalizedContent
    return try envelope(.completed(summary: summary, stopReason: stopReason))
  }

  public func failed(code: String, summary: String) throws -> AgentEventEnvelope {
    try envelope(.failed(code: code, summary: summary))
  }

  public func interrupted() throws -> AgentEventEnvelope {
    try envelope(.interrupted)
  }

  private func envelope(_ event: AgentEvent) throws -> AgentEventEnvelope {
    let envelope = try AgentEventEnvelope(
      taskID: taskID,
      providerID: binding.providerID,
      providerSessionID: binding.providerSessionID,
      providerRunID: binding.providerRunID,
      providerSequence: nextProviderSequence,
      event: event
    )
    nextProviderSequence += 1
    return envelope
  }

  private var assistantMessageKey: String {
    assistantMessageIndex == 0
      ? "message:assistant"
      : "message:assistant:\(assistantMessageIndex)"
  }

  private func validateSession(_ sessionID: String) throws {
    guard sessionID == binding.providerSessionID else {
      throw DeepSeekHarnessACPError.sessionMismatch
    }
  }

  private func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  private func approval(
    _ request: DeepSeekHarnessACPPermissionRequest
  ) throws -> AgentEventEnvelope {
    let approval = try AgentApprovalRequest(
      approvalID: request.approvalID,
      taskID: taskID,
      binding: binding,
      providerItemID: request.toolCallID,
      kind: Self.approvalKind(request.kind),
      title: Self.safeText(request.title) ?? "DeepSeek Harness permission request",
      relativePaths: Self.relativePaths(from: request.rawInput, projectRoot: projectRoot),
      normalizedCommand: Self.safeCommand(Self.stringValue(request.rawInput, key: "command")),
      networkTarget: Self.safeNetworkTarget(
        Self.stringValue(request.rawInput, key: "url")
          ?? Self.stringValue(request.rawInput, key: "uri")
          ?? Self.stringValue(request.rawInput, key: "target")
      ),
      options: request.options
    )
    return try envelope(.approvalRequested(approval))
  }

  private func tool(
    _ update: DeepSeekHarnessACPToolUpdate
  ) throws -> AgentEventEnvelope {
    try validateIdentifier(update.toolCallID, field: "tool.toolCallID")
    if tools[update.toolCallID] == nil, tools.count >= Self.maximumTools {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    var state = tools[update.toolCallID] ?? ToolState()
    if let title = update.title, !title.isEmpty { state.title = title }
    if let kind = update.kind { state.kind = kind }
    if let rawInput = update.rawInput { state.arguments = rawInput.encodedString() }
    state.status = update.status
    let payload = try AgentToolUpdate(
      key: "tool:\(update.toolCallID)",
      name: state.title ?? state.kind ?? "tool",
      title: state.title,
      kind: state.kind,
      status: state.status,
      arguments: state.arguments
    )
    tools[update.toolCallID] = state
    return try envelope(.tool(payload))
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

  private static func stringValue(_ value: ACPJSONValue?, key: String) -> String? {
    value?.objectValue?[key]?.stringValue
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
    from value: ACPJSONValue?,
    projectRoot: String?
  ) -> [String] {
    guard let projectRoot, let input = value?.objectValue else { return [] }
    let keys = ["path", "filePath", "filepath", "file", "source", "destination"]
    var paths = Set<String>()
    for key in keys {
      guard let value = input[key]?.stringValue,
        let path = relativePath(value, projectRoot: projectRoot)
      else { continue }
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
}
