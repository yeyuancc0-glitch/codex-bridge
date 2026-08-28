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
      update["sessionUpdate"]?.stringValue == "agent_message_chunk",
      let content = update["content"]?.objectValue,
      content["type"]?.stringValue == "text",
      let text = content["text"]?.stringValue
    else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    try requireSession(sessionID)
    guard text.utf8.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      !text.contains("\0")
    else {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    guard !text.isEmpty else { return }
    yield(.textDelta(sessionID: sessionID, text: text))
  }

  func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    broker.failAll(with: Self.map(error ?? DeepSeekHarnessACPError.transportClosed))
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
    broker.failAll(with: error)
    eventContinuation.finish()
    await transport.close()
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
