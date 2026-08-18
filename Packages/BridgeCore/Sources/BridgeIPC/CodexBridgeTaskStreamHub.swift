import Foundation

public final class CodexBridgeTaskStreamHub: @unchecked Sendable {
  private let lock = NSLock()
  private var streams: [String: [UUID: AsyncStream<IPCTaskConversationPush>.Continuation]] = [:]

  public init() {}

  public func register(taskID: String) -> AsyncStream<IPCTaskConversationPush> {
    lock.lock()
    defer { lock.unlock() }
    var continuation: AsyncStream<IPCTaskConversationPush>.Continuation!
    let stream = AsyncStream<IPCTaskConversationPush>(
      bufferingPolicy: .bufferingNewest(128)
    ) { continuation = $0 }
    streams[taskID, default: [:]][UUID()] = continuation
    return stream
  }

  public func unregisterAll(taskID: String) {
    lock.lock()
    streams[taskID] = nil
    lock.unlock()
  }

  public func clear() {
    lock.lock()
    streams.removeAll(keepingCapacity: false)
    lock.unlock()
  }

  public func push(_ payload: Data) {
    guard
      let push = try? JSONDecoder().decode(IPCTaskConversationPush.self, from: payload)
    else {
      return
    }
    lock.lock()
    let active = Array(streams[push.taskID]?.values ?? [:].values)
    lock.unlock()
    for continuation in active {
      switch continuation.yield(push) {
      case .enqueued, .dropped, .terminated:
        continue
      @unknown default:
        continue
      }
    }
  }
}

public final class CodexBridgeTaskStreamBridge: NSObject, CodexBridgeTaskStreamListener {
  private let hub: CodexBridgeTaskStreamHub

  public init(hub: CodexBridgeTaskStreamHub) {
    self.hub = hub
    super.init()
  }

  public func push(_ payload: Data) {
    hub.push(payload)
  }
}
