import Foundation
@preconcurrency import NIOCore

package final class MCPHTTPWritability: @unchecked Sendable {
  private let lock = NSLock()
  private var isWritable = true
  private var isOpen = true
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  func update(isWritable: Bool, isOpen: Bool) {
    var pending: [CheckedContinuation<Void, any Error>] = []
    var error: (any Error)?
    lock.withLock {
      guard self.isOpen else { return }
      self.isWritable = isWritable
      self.isOpen = isOpen
      guard isWritable || !isOpen else { return }
      pending = Array(waiters.values)
      waiters.removeAll(keepingCapacity: true)
      if !isOpen {
        error = MCPHTTPWriteError.channelClosed
      }
    }
    for waiter in pending {
      if let error {
        waiter.resume(throwing: error)
      } else {
        waiter.resume()
      }
    }
  }

  func waitUntilWritable() async throws {
    let identifier = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var outcome: Result<Void, any Error>?
        lock.withLock {
          if Task.isCancelled {
            outcome = .failure(CancellationError())
          } else if !isOpen {
            outcome = .failure(MCPHTTPWriteError.channelClosed)
          } else if isWritable {
            outcome = .success(())
          } else {
            waiters[identifier] = continuation
          }
        }
        if let outcome {
          continuation.resume(with: outcome)
        }
      }
    } onCancel: {
      self.cancelWaiter(identifier)
    }
  }

  private func cancelWaiter(_ identifier: UUID) {
    let waiter = lock.withLock {
      waiters.removeValue(forKey: identifier)
    }
    if let waiter {
      waiter.resume(throwing: CancellationError())
    }
  }
}

enum MCPHTTPWriteError: Error {
  case channelClosed
  case responseChunkTooLarge
}

extension TimeAmount {
  init(_ duration: Duration) {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let attoseconds = components.attoseconds / 1_000_000_000
    let nanoseconds = seconds.overflow ? Int64.max : seconds.partialValue
    let (combined, overflowed) = nanoseconds.addingReportingOverflow(Int64(attoseconds))
    self = .nanoseconds(overflowed ? Int64.max : combined)
  }
}
