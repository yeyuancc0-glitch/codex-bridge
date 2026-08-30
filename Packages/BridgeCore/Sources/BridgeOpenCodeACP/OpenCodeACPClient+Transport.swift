import BridgeACP
import BridgeAgentCore
import Foundation

struct ACPClientResponse: Sendable {
  let value: ACPJSONValue
  let eventSequenceBarrier: Int64
}

extension OpenCodeACPClient {
  func request(
    method: String,
    params: ACPJSONValue,
    timeout override: Duration? = nil
  ) async throws -> ACPClientResponse {
    guard started, !closed else { throw OpenCodeACPError.transportClosed }
    do {
      let response = try await requestBroker.request(
        method: method,
        params: params,
        timeout: override
      )
      return ACPClientResponse(
        value: response.value,
        eventSequenceBarrier: response.eventSequenceBarrier
      )
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  func send(_ message: ACPWireMessage) async throws {
    guard !closed else { throw OpenCodeACPError.transportClosed }
    do {
      try await requestBroker.send(message)
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  func receive(_ frame: Data) async {
    let message: ACPWireMessage
    do {
      message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    } catch {
      await failConnection(OpenCodeACPError.invalidMessage)
      return
    }
    do {
      switch try BridgeACP.ACPMessageDispatcher.dispatch(message) {
      case .serverRequest(let id, let method, let params):
        await handleServerRequest(id: id, method: method, params: params)
      case .response(let id, let result, let error):
        requestBroker.resolve(
          id: id,
          result: result,
          error: error,
          eventSequenceBarrier: nextEventSequence
        )
      case .notification(let method, let params):
        yield(.notification(OpenCodeACPNotification(method: method, params: params)))
      }
    } catch {
      await failConnection(Self.compatibilityError(for: error))
    }
  }

  func yield(_ event: OpenCodeACPClientEvent) {
    let envelope = OpenCodeACPClientEventEnvelope(
      sequence: nextEventSequence,
      event: event
    )
    nextEventSequence += 1
    if case .dropped = eventContinuation.yield(envelope) {
      Task { [weak self] in await self?.failConnection(OpenCodeACPError.transportClosed) }
    }
  }

  func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    requestBroker.failAll(with: error ?? OpenCodeACPError.transportClosed)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
  }

  func failConnection(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    requestBroker.failAll(with: error)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
    await requestBroker.close()
  }

  private static func compatibilityError(for error: any Error) -> OpenCodeACPError {
    if let error = error as? OpenCodeACPError { return error }
    if let error = error as? BridgeACP.ACPError {
      switch error {
      case .invalidMessage: return .invalidMessage
      case .malformedResponse: return .malformedResponse
      case .remote(let code, let message): return .remote(code: code, message: message)
      case .requestTimedOut: return .requestTimedOut
      case .transportClosed: return .transportClosed
      case .processExited(let code): return .processExited(code)
      case .oversizedFrame: return .oversizedFrame
      }
    }
    return .transportClosed
  }
}
