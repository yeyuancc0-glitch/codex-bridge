import Foundation
@preconcurrency import NIOCore

package final class MCPHTTPRequestLease: @unchecked Sendable {
  private let lock = NSLock()
  private var admission: MCPHTTPAdmission?

  fileprivate init(admission: MCPHTTPAdmission) {
    self.admission = admission
  }

  package func release() {
    let admission = lock.withLock { () -> MCPHTTPAdmission? in
      let current = self.admission
      self.admission = nil
      return current
    }
    admission?.releaseRequest()
  }

  deinit { release() }
}

package final class MCPHTTPAdmission: @unchecked Sendable {
  private struct State {
    var channels: [ObjectIdentifier: any Channel] = [:]
    var activeRequests = 0
    var isStopping = false
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private let lock = NSLock()
  private let maximumConnections: Int
  private let maximumActiveRequests: Int
  private var state = State()

  package init(maximumConnections: Int, maximumActiveRequests: Int) {
    self.maximumConnections = maximumConnections
    self.maximumActiveRequests = maximumActiveRequests
  }

  package func register(_ channel: any Channel) -> Bool {
    lock.withLock {
      guard !state.isStopping, state.channels.count < maximumConnections else { return false }
      state.channels[ObjectIdentifier(channel)] = channel
      return true
    }
  }

  package func unregister(_ channel: any Channel) {
    _ = lock.withLock {
      state.channels.removeValue(forKey: ObjectIdentifier(channel))
    }
  }

  package func admitRequest() -> MCPHTTPRequestLease? {
    lock.withLock {
      guard !state.isStopping, state.activeRequests < maximumActiveRequests else { return nil }
      state.activeRequests += 1
      return MCPHTTPRequestLease(admission: self)
    }
  }

  fileprivate func releaseRequest() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      state.activeRequests = max(0, state.activeRequests - 1)
      guard state.activeRequests == 0 else { return [] }
      let current = state.drainWaiters
      state.drainWaiters.removeAll(keepingCapacity: false)
      return current
    }
    for waiter in waiters { waiter.resume() }
  }

  package func beginStopping() {
    lock.withLock { state.isStopping = true }
  }

  package func resetAfterStop() {
    lock.withLock { state.isStopping = false }
  }

  package func waitForRequestDrain() async {
    if lock.withLock({ state.activeRequests == 0 }) { return }
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        guard state.activeRequests > 0 else { return true }
        state.drainWaiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  package func metrics() -> MCPHTTPMetrics {
    lock.withLock {
      MCPHTTPMetrics(
        activeConnections: state.channels.count,
        activeRequests: state.activeRequests
      )
    }
  }

  package func activeChannels() -> [any Channel] {
    lock.withLock { Array(state.channels.values) }
  }
}
