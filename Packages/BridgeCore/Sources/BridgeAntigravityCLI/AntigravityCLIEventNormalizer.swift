import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import BridgeSecurity
import Foundation

public enum AntigravityPermissionEvidence {
  public static func detected(in output: BoundedProcessOutput) -> Bool {
    detected(in: output.head + "\n" + output.tail)
  }

  public static func detected(in value: String?) -> Bool {
    guard let value else { return false }
    let combined = value.lowercased()
    guard !combined.isEmpty else { return false }
    let denialMarkers = [
      "soft-denied",
      "soft denied",
      "auto-denied",
      "auto denied",
      "permission denied",
      "permission was denied",
      "denied permission",
      "user denied permission",
      "requires approval",
      "could not obtain approval",
      "headless mode cannot prompt",
      "not allowed by permission",
      "grant permission",
      "add an allow rule",
      "add an allow-rule",
    ]
    return denialMarkers.contains { combined.contains($0) }
  }
}

public actor AntigravityCLIEventNormalizer {
  private struct ContentState: Sendable {
    var content: String
  }

  private let taskID: TaskID
  private let binding: AgentBinding
  private let projectRoot: String
  private var sequence: Int64 = 0
  private var turnOrdinal = 0
  private var latestMessageKey: String?
  private var contents: [String: ContentState] = [:]
  private static let maximumContentBytes = 256 * 1_024
  private static let maximumContentStreams = 64
  private static let maximumLocations = 128

  public init(taskID: TaskID, binding: AgentBinding, projectRoot: String) {
    self.taskID = taskID
    self.binding = binding
    self.projectRoot = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
  }

  public func normalize(_ update: AntigravityStepUpdate) throws -> [AgentEventEnvelope] {
    try validateSession(update.conversationID)
    let isKnownState =
      update.state == "ACTIVE" || update.state == "DONE"
      || (update.state == "ERROR" && update.stepType == "tool")
    guard update.stepIndex >= 0, isKnownState
    else {
      throw AntigravityCLIError.invalidMessage
    }

    var events: [AgentEventEnvelope] = []
    switch update.stepType {
    case "agent_response":
      try accumulateContent(update)
    case "tool":
      events.append(try tool(update))
    default:
      if update.subagentInfo != nil {
        events.append(try subagent(update))
      }
    }
    if let usage = try usage(update.usage) { events.append(usage) }
    return events
  }

  public func normalize(
    _ result: AntigravityResult,
    permissionDenied: Bool,
    terminal: Bool,
    permissionMode: String? = nil
  ) throws -> [AgentEventEnvelope] {
    try validateSession(result.conversationID)
    var events: [AgentEventEnvelope] = []
    if let usage = try usage(result.usage) { events.append(usage) }
    let safeResponse = Self.safeContent(result.response)
    if !safeResponse.isEmpty {
      let key = latestMessageKey ?? "message:result:\(turnOrdinal)"
      contents[key] = ContentState(content: safeResponse)
      events.append(
        try envelope(
          .content(
            AgentContentUpdate(
              key: key,
              role: .assistant,
              kind: .message,
              mode: .full,
              content: safeResponse,
              isFinal: true,
              authoritative: true
            )
          )
        )
      )
    }
    turnOrdinal += 1
    latestMessageKey = nil
    contents.removeAll(keepingCapacity: true)

    guard terminal else { return events }
    if permissionDenied {
      events.append(try envelope(.approvalAutomaticallyDenied("antigravity-soft-denial")))
      events.append(
        try envelope(
          .failed(
            code: "antigravity_permission_denied",
            summary: AntigravityCLIHeadlessPolicy.permissionDeniedSummary(
              permissionMode: permissionMode
            )
          )
        )
      )
      return events
    }

    let status = result.status.uppercased()
    switch status {
    case "SUCCESS":
      let summary = Self.summary(
        result.response,
        fallback: "Antigravity completed the task."
      )
      events.append(try envelope(.completed(summary: summary, stopReason: status)))
    case "CANCELED", "INTERRUPTED":
      events.append(try envelope(.interrupted))
    default:
      let summary = Self.summary(
        result.error ?? result.response,
        fallback: "Antigravity returned terminal status \(status)."
      )
      events.append(
        try envelope(
          .failed(
            code: "antigravity_\(Self.safeCode(status))",
            summary: summary
          )
        )
      )
    }
    return events
  }

  public func failed(code: String, summary: String) throws -> AgentEventEnvelope {
    try envelope(.failed(code: code, summary: summary))
  }

  public func interrupted() throws -> AgentEventEnvelope {
    try envelope(.interrupted)
  }

  private func accumulateContent(_ update: AntigravityStepUpdate) throws {
    guard let delta = update.textDelta, !delta.isEmpty else { return }
    let key = "message:\(update.stepIndex)"
    if contents[key] == nil, contents.count >= Self.maximumContentStreams {
      throw AntigravityCLIError.oversizedFrame
    }
    let existing = contents[key]?.content ?? ""
    let combined = existing + delta
    guard combined.utf8.count <= Self.maximumContentBytes else {
      throw AntigravityCLIError.oversizedFrame
    }
    contents[key] = ContentState(content: combined)
    latestMessageKey = key
  }

  private func tool(_ update: AntigravityStepUpdate) throws -> AgentEventEnvelope {
    let info = update.toolInfo
    let error = info?.error ?? update.error
    let name = Self.safeIdentifier(info?.name ?? update.toolName) ?? "tool"
    let status: AgentToolStatus
    if update.state == "ERROR" || error != nil {
      status = .failed
    } else {
      status = update.state == "DONE" ? .completed : .inProgress
    }
    let payload = try AgentToolUpdate(
      key: "tool:\(update.stepIndex)",
      name: name,
      title: name,
      kind: name,
      status: status,
      arguments: Self.safeArguments(info?.parameters),
      output: Self.safeOutput(error?.message ?? info?.output),
      locations: locations(in: info?.parameters)
    )
    return try envelope(.tool(payload))
  }

  private func subagent(_ update: AntigravityStepUpdate) throws -> AgentEventEnvelope {
    let subagents = update.subagentInfo?.subagents ?? []
    let roles = subagents.compactMap { Self.safeText($0.role, maximumBytes: 256) }
    let output =
      roles.isEmpty
      ? "Antigravity updated a subagent run."
      : "Subagents: " + roles.prefix(16).joined(separator: ", ")
    let payload = try AgentToolUpdate(
      key: "tool:subagent:\(update.stepIndex)",
      name: "subagent",
      title: "Subagent",
      kind: "subagent",
      status: update.state == "DONE" ? .completed : .inProgress,
      output: output
    )
    return try envelope(.tool(payload))
  }

  private func usage(_ usage: AntigravityUsage?) throws -> AgentEventEnvelope? {
    guard let total = usage?.totalTokens, total >= 0 else { return nil }
    return try envelope(
      .usage(
        AgentUsageUpdate(
          usedTokens: total,
          contextSize: total,
          costAmount: nil,
          currency: nil
        )
      )
    )
  }

  private func locations(in value: AntigravityJSONValue?) -> [String] {
    guard let value else { return [] }
    var result = Set<String>()
    collectLocations(value, key: nil, depth: 0, into: &result)
    let sorted = result.sorted()
    return Array(sorted[0..<min(sorted.count, Self.maximumLocations)])
  }

  private func collectLocations(
    _ value: AntigravityJSONValue,
    key: String?,
    depth: Int,
    into result: inout Set<String>
  ) {
    guard depth <= 4, result.count < Self.maximumLocations else { return }
    switch value {
    case .object(let object):
      for (childKey, child) in object where result.count < Self.maximumLocations {
        collectLocations(child, key: childKey, depth: depth + 1, into: &result)
      }
    case .array(let values):
      for child in values.prefix(Self.maximumLocations) where result.count < Self.maximumLocations {
        collectLocations(child, key: key, depth: depth + 1, into: &result)
      }
    case .string(let candidate):
      guard Self.isPathKey(key), let path = normalizedProjectPath(candidate) else { return }
      result.insert(path)
    default:
      return
    }
  }

  private func normalizedProjectPath(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 4 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    let raw: String
    if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
      raw = url.path
    } else {
      raw = value
    }
    let absolute =
      raw.hasPrefix("/")
      ? URL(fileURLWithPath: raw).standardizedFileURL.path
      : URL(fileURLWithPath: projectRoot, isDirectory: true)
        .appendingPathComponent(raw).standardizedFileURL.path
    guard absolute == projectRoot || absolute.hasPrefix(projectRoot + "/") else { return nil }
    return absolute
  }

  private func validateSession(_ sessionID: String) throws {
    guard binding.providerSessionID == sessionID else {
      throw AntigravityCLIError.sessionMismatch
    }
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

  private static func isPathKey(_ key: String?) -> Bool {
    guard let key else { return false }
    let normalized =
      key
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
    return normalized.contains("path")
      || ["file", "source", "destination", "target", "uri", "workspace"].contains(normalized)
  }

  private static func safeIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
      !trimmed.contains("\0"), trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return trimmed
  }

  private static func safeArguments(_ value: AntigravityJSONValue?) -> String? {
    guard let encoded = value?.encodedString(), encoded.utf8.count <= 64 * 1_024 else {
      return nil
    }
    return OutboundContentSecurity.isSafeSecrets(encoded) ? encoded : "[REDACTED]"
  }

  private static func safeOutput(_ value: String?) -> String? {
    guard let value else { return nil }
    return OutboundContentSecurity.redactedCommandOutput(
      value,
      maximumUTF8Bytes: 256 * 1_024
    )
  }

  private static func safeText(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, !value.contains("\0") else { return nil }
    return OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximumBytes)
  }

  private static func safeContent(_ value: String) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximumContentBytes)
  }

  private static func summary(_ value: String?, fallback: String) -> String {
    guard let value else { return fallback }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallback }
    let redacted = OutboundContentSecurity.redacted(trimmed, maximumUTF8Bytes: 4 * 1_024)
    return redacted.isEmpty ? fallback : redacted
  }

  private static func safeCode(_ value: String) -> String {
    let code = value.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "_"
    }
    let normalized = String(code).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return normalized.isEmpty ? "error" : String(normalized.prefix(64))
  }
}
