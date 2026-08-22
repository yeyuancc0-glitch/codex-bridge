import BridgeIPC
import Foundation

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
