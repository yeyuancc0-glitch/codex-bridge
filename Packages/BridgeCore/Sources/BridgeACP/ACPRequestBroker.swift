import Foundation

public struct ACPRequestResponse: Equatable, Sendable {
  public let value: ACPJSONValue
  public let eventSequenceBarrier: Int64

  public init(value: ACPJSONValue, eventSequenceBarrier: Int64 = 0) {
    self.value = value
    self.eventSequenceBarrier = eventSequenceBarrier
  }
}

public final class ACPRequestBroker: @unchecked Sendable {
  private struct Pending {
    let continuation: CheckedContinuation<ACPRequestResponse, any Error>
    var timeoutTask: Task<Void, Never>?
  }

  private let transport: any ACPTransport
  private let requestTimeout: Duration
  private let lock = NSLock()
  private var nextRequestID: Int64 = 1
  private var pending: [ACPRequestID: Pending] = [:]
  private var closed = false

  public init(transport: any ACPTransport, requestTimeout: Duration = .seconds(30)) {
    self.transport = transport
    self.requestTimeout = requestTimeout
  }

  public func request(
    method: String,
    params: ACPJSONValue,
    timeout override: Duration? = nil
  ) async throws -> ACPRequestResponse {
    let id = try allocateRequestID()
    let message = ACPWireMessage(id: id, method: method, params: params)
    let data = try JSONEncoder().encode(message)
    let timeout = override ?? requestTimeout

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let accepted = lock.withLock { () -> Bool in
          guard !closed, !Task.isCancelled else { return false }
          pending[id] = Pending(continuation: continuation, timeoutTask: nil)
          return true
        }
        guard accepted else {
          continuation.resume(
            throwing: Task.isCancelled ? CancellationError() : ACPError.transportClosed
          )
          return
        }

        if Task.isCancelled {
          fail(id: id, error: CancellationError())
          return
        }

        let timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          self?.timeout(id: id)
        }
        let timeoutAttached = lock.withLock { () -> Bool in
          guard var value = pending[id] else { return false }
          value.timeoutTask = timeoutTask
          pending[id] = value
          return true
        }
        guard timeoutAttached else {
          timeoutTask.cancel()
          return
        }

        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.transport.send(data)
          } catch {
            self.fail(id: id, error: error)
          }
        }
      }
    } onCancel: {
      self.fail(id: id, error: CancellationError())
    }
  }

  public func send(_ message: ACPWireMessage) async throws {
    let data = try JSONEncoder().encode(message)
    guard lock.withLock({ !closed }) else { throw ACPError.transportClosed }
    try await transport.send(data)
  }

  @discardableResult
  public func resolve(
    id: ACPRequestID,
    result: ACPJSONValue?,
    error: ACPWireError?,
    eventSequenceBarrier: Int64
  ) -> Bool {
    guard let pending = removePending(id) else { return false }
    guard (result != nil) != (error != nil) else {
      pending.continuation.resume(throwing: ACPError.malformedResponse)
      return true
    }
    if let error {
      guard error.message.utf8.count <= 4 * 1_024, !error.message.contains("\0") else {
        pending.continuation.resume(throwing: ACPError.malformedResponse)
        return true
      }
      pending.continuation.resume(
        throwing: ACPError.remote(code: error.code, message: error.message))
    } else if let result {
      pending.continuation.resume(
        returning: ACPRequestResponse(
          value: result,
          eventSequenceBarrier: eventSequenceBarrier
        )
      )
    }
    return true
  }

  public func fail(id: ACPRequestID, error: any Error) {
    guard let pending = removePending(id) else { return }
    pending.continuation.resume(throwing: error)
  }

  public func failAll(with error: any Error) {
    let values = lock.withLock { () -> [Pending] in
      let values = Array(pending.values)
      pending.removeAll()
      return values
    }
    for value in values {
      value.timeoutTask?.cancel()
      value.continuation.resume(throwing: error)
    }
  }

  public func close() async {
    let shouldClose = lock.withLock { () -> Bool in
      guard !closed else { return false }
      closed = true
      return true
    }
    guard shouldClose else { return }
    failAll(with: ACPError.transportClosed)
    await transport.close()
  }

  private func allocateRequestID() throws -> ACPRequestID {
    let id = lock.withLock { () -> ACPRequestID? in
      guard !closed, nextRequestID > 0, nextRequestID < Int64.max else {
        return nil
      }
      defer { nextRequestID += 1 }
      return ACPRequestID.integer(nextRequestID)
    }
    guard let id else {
      throw ACPError.transportClosed
    }
    return id
  }

  private func removePending(_ id: ACPRequestID) -> Pending? {
    lock.withLock {
      guard let value = pending.removeValue(forKey: id) else { return nil }
      value.timeoutTask?.cancel()
      return value
    }
  }

  private func timeout(id: ACPRequestID) {
    guard let pending = removePending(id) else { return }
    pending.continuation.resume(throwing: ACPError.requestTimedOut)
  }
}
