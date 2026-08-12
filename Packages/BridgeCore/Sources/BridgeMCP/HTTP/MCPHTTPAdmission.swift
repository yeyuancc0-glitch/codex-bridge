import Foundation
@preconcurrency import NIOCore

package final class MCPHTTPAdmission: @unchecked Sendable {
  private struct State {
    var channels: [ObjectIdentifier: any Channel] = [:]
    var activeRequests = 0
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
      guard state.channels.count < maximumConnections else { return false }
      state.channels[ObjectIdentifier(channel)] = channel
      return true
    }
  }

  package func unregister(_ channel: any Channel) {
    _ = lock.withLock {
      state.channels.removeValue(forKey: ObjectIdentifier(channel))
    }
  }

  package func admitRequest() -> Bool {
    lock.withLock {
      guard state.activeRequests < maximumActiveRequests else { return false }
      state.activeRequests += 1
      return true
    }
  }

  package func releaseRequest() {
    lock.withLock {
      state.activeRequests = max(0, state.activeRequests - 1)
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
