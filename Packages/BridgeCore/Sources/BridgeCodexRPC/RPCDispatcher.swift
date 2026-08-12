import Foundation

public actor RPCDispatcher {
  private struct PendingRequest {
    let continuation: CheckedContinuation<JSONValue, any Error>
    let timeoutTask: Task<Void, Never>
    let sendTask: Task<Void, Never>
  }

  public nonisolated let events: AsyncStream<AppServerEvent>

  private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
  private let eventBufferLimit: Int
  private var pending: [RequestID: PendingRequest] = [:]
  private var terminalError: CodexRPCError?

  public init(eventBufferLimit: Int = 256) {
    let eventBufferLimit = max(1, eventBufferLimit)
    let pair = AsyncStream.makeStream(
      of: AppServerEvent.self,
      bufferingPolicy: .bufferingNewest(eventBufferLimit)
    )
    events = pair.stream
    eventContinuation = pair.continuation
    self.eventBufferLimit = eventBufferLimit
  }

  func request(
    id: RequestID,
    method: String,
    timeoutNanoseconds: UInt64,
    send: @escaping @Sendable () async throws -> Void
  ) async throws -> JSONValue {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        beginRequest(
          id: id,
          method: method,
          timeoutNanoseconds: timeoutNanoseconds,
          continuation: continuation,
          send: send
        )
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  func receive(_ value: JSONValue) throws {
    try dispatch(RPCEnvelope.decode(value))
  }

  func terminate(with error: CodexRPCError) {
    guard terminalError == nil else { return }
    terminalError = error
    let requests = pending.values
    pending.removeAll(keepingCapacity: false)

    for request in requests {
      request.timeoutTask.cancel()
      request.sendTask.cancel()
      request.continuation.resume(throwing: error)
    }
    eventContinuation.finish()
  }

  private func beginRequest(
    id: RequestID,
    method: String,
    timeoutNanoseconds: UInt64,
    continuation: CheckedContinuation<JSONValue, any Error>,
    send: @escaping @Sendable () async throws -> Void
  ) {
    if let terminalError {
      continuation.resume(throwing: terminalError)
      return
    }
    guard pending[id] == nil else {
      continuation.resume(
        throwing: CodexRPCError.malformedMessage("duplicate request id")
      )
      return
    }

    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
      } catch {
        return
      }
      await self?.timeOut(id: id, method: method)
    }
    let sendTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        try await send()
      } catch is CancellationError {
        return
      } catch let error as CodexRPCError {
        await self?.fail(id: id, with: error)
      } catch {
        await self?.fail(
          id: id,
          with: .transportWriteFailed(error.localizedDescription)
        )
      }
    }
    pending[id] = PendingRequest(
      continuation: continuation,
      timeoutTask: timeoutTask,
      sendTask: sendTask
    )
  }

  private func dispatch(_ message: InboundRPCMessage) throws {
    switch message {
    case .response(let id, let result):
      complete(id: id, with: .success(result))
    case .error(let id, let error):
      complete(
        id: id,
        with: .failure(
          .remote(code: error.code, message: error.message, data: error.data)
        )
      )
    case .notification(let notification):
      try publish(.notification(notification))
    case .serverRequest(let request):
      try publish(.serverRequest(request))
    }
  }

  private func publish(_ event: AppServerEvent) throws {
    switch eventContinuation.yield(event) {
    case .enqueued:
      return
    case .dropped:
      throw CodexRPCError.eventBufferOverflow(maximumEvents: eventBufferLimit)
    case .terminated:
      return
    @unknown default:
      throw CodexRPCError.eventBufferOverflow(maximumEvents: eventBufferLimit)
    }
  }

  private func complete(
    id: RequestID,
    with result: Result<JSONValue, CodexRPCError>
  ) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.sendTask.cancel()
    request.continuation.resume(with: result.mapError { $0 as any Error })
  }

  private func timeOut(id: RequestID, method: String) {
    fail(id: id, with: .timeout(method: method))
  }

  private func fail(id: RequestID, with error: CodexRPCError) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.sendTask.cancel()
    request.continuation.resume(throwing: error)
  }

  private func cancel(id: RequestID) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.sendTask.cancel()
    request.continuation.resume(throwing: CancellationError())
  }
}
