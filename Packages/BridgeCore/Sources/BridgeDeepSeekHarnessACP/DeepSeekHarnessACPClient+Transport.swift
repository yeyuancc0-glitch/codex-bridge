import BridgeACP
import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPClient {
  func request(
    method: String,
    params: ACPJSONValue,
    timeout: Duration? = nil
  ) async throws -> ACPRequestResponse {
    guard started, !closed else { throw DeepSeekHarnessACPError.transportClosed }
    do {
      return try await broker.request(method: method, params: params, timeout: timeout)
    } catch {
      throw Self.map(error)
    }
  }

  func receive(_ frame: Data) async {
    guard !closed else { return }
    let message: ACPWireMessage
    do {
      message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    } catch {
      await failConnection(DeepSeekHarnessACPError.invalidMessage)
      return
    }
    do {
      switch try ACPMessageDispatcher.dispatch(message) {
      case .response(let id, let result, let error):
        let resolved = broker.resolve(
          id: id,
          result: result,
          error: error,
          eventSequenceBarrier: nextEventSequence
        )
        guard resolved else {
          await failConnection(DeepSeekHarnessACPError.malformedResponse)
          return
        }
      case .notification(let method, let params):
        try handleNotification(method: method, params: params)
      case .serverRequest(let id, let method, let params):
        try await handleServerRequest(id: id, method: method, params: params)
      }
    } catch {
      await failConnection(Self.map(error))
    }
  }

  private func handleNotification(method: String, params: ACPJSONValue?) throws {
    guard method == "session/update",
      let object = params?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let update = object["update"]?.objectValue,
      let updateType = update["sessionUpdate"]?.stringValue
    else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    try requireSession(sessionID)
    switch updateType {
    case "agent_message_chunk":
      try handleTextUpdate(sessionID: sessionID, update: update)
    case "tool_call", "tool_call_update":
      try handleToolUpdate(sessionID: sessionID, update: update)
    default:
      throw DeepSeekHarnessACPError.invalidMessage
    }
  }

  private func handleTextUpdate(
    sessionID: String,
    update: [String: ACPJSONValue]
  ) throws {
    guard
      let content = update["content"]?.objectValue,
      content["type"]?.stringValue == "text",
      let text = content["text"]?.stringValue
    else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    guard text.utf8.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      !text.contains("\0")
    else {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    guard !text.isEmpty else { return }
    yield(.textDelta(sessionID: sessionID, text: text))
  }

  private func handleToolUpdate(
    sessionID: String,
    update: [String: ACPJSONValue]
  ) throws {
    guard let toolCallID = update["toolCallId"]?.stringValue,
      let statusValue = update["status"]?.stringValue,
      let status = Self.toolStatus(statusValue)
    else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    try validateIdentifier(toolCallID, field: "tool.toolCallID")
    let title = update["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    if let title {
      guard title.utf8.count <= 1_024, !title.contains("\0") else {
        throw DeepSeekHarnessACPError.oversizedFrame
      }
    }
    let kind = update["kind"]?.stringValue
    if let kind { try validateIdentifier(kind, field: "tool.kind") }
    yield(
      .toolUpdated(
        DeepSeekHarnessACPToolUpdate(
          sessionID: sessionID,
          toolCallID: toolCallID,
          title: title,
          kind: kind,
          status: status,
          rawInput: update["rawInput"]
        )
      )
    )
  }

  private static func toolStatus(_ value: String) -> AgentToolStatus? {
    switch value {
    case "pending": .pending
    case "in_progress": .inProgress
    case "completed": .completed
    case "failed": .failed
    default: nil
    }
  }

  func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    let failure = Self.map(error ?? DeepSeekHarnessACPError.transportClosed)
    rememberTerminalFailure(failure)
    broker.failAll(with: failure)
    eventContinuation.finish()
  }

  func failConnection(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    readerTask?.cancel()
    readerTask = nil
    let failure = Self.map(error)
    rememberTerminalFailure(failure)
    broker.failAll(with: failure)
    eventContinuation.finish()
    await transport.close()
  }

  private func rememberTerminalFailure(_ error: any Error) {
    guard terminalFailureStorage == nil else { return }
    guard let failure = Self.map(error) as? DeepSeekHarnessACPError else { return }
    if case .remote(let code, let message) = failure {
      terminalFailureStorage = .remote(
        code: code,
        message: DeepSeekHarnessACPDiagnostic.sanitizeProviderMessage(message)
      )
    } else {
      terminalFailureStorage = failure
    }
  }

  func yield(_ event: DeepSeekHarnessACPClientEvent) {
    let envelope = DeepSeekHarnessACPClientEventEnvelope(
      sequence: nextEventSequence,
      event: event
    )
    nextEventSequence += 1
    if case .dropped = eventContinuation.yield(envelope) {
      Task { [weak self] in
        await self?.failConnection(DeepSeekHarnessACPError.transportClosed)
      }
    }
  }

  static func map(_ error: any Error) -> any Error {
    if error is DeepSeekHarnessACPError || error is AgentRuntimeError { return error }
    guard let error = error as? ACPError else { return DeepSeekHarnessACPError.transportClosed }
    switch error {
    case .invalidMessage: return DeepSeekHarnessACPError.invalidMessage
    case .malformedResponse: return DeepSeekHarnessACPError.malformedResponse
    case .remote(let code, let message):
      return DeepSeekHarnessACPError.remote(code: code, message: message)
    case .requestTimedOut: return DeepSeekHarnessACPError.requestTimedOut
    case .transportClosed: return DeepSeekHarnessACPError.transportClosed
    case .processExited(let code): return DeepSeekHarnessACPError.processExited(code)
    case .oversizedFrame: return DeepSeekHarnessACPError.oversizedFrame
    }
  }
}
