import BridgeAgentCore
import BridgeDomain
import Foundation

public actor DeepSeekHarnessACPEventNormalizer {
  private let taskID: TaskID
  private let binding: AgentBinding
  private var content = ""
  private var nextProviderSequence: Int64 = 0

  public init(taskID: TaskID, binding: AgentBinding) {
    self.taskID = taskID
    self.binding = binding
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
        key: "message:assistant",
        role: .assistant,
        kind: .message,
        mode: .delta,
        content: text,
        baseContentLength: baseLength,
        isFinal: false,
        authoritative: false
      )
      return try envelope(.content(update))
    case .approvalAutomaticallyDenied(let sessionID, let toolCallID):
      try validateSession(sessionID)
      try validateIdentifier(toolCallID, field: "permission.toolCallID")
      return try envelope(.approvalAutomaticallyDenied(toolCallID))
    }
  }

  public func finalizeContent() throws -> [AgentEventEnvelope] {
    guard !content.isEmpty else { return [] }
    let update = try AgentContentUpdate(
      key: "message:assistant",
      role: .assistant,
      kind: .message,
      mode: .full,
      content: content,
      baseContentLength: nil,
      isFinal: true,
      authoritative: true
    )
    return [try envelope(.content(update))]
  }

  public func completed(stopReason: String) throws -> AgentEventEnvelope {
    let summary = content.isEmpty ? "DeepSeek Harness turn completed." : content
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
}
