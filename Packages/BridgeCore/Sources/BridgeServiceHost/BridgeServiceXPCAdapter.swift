import BridgeIPC
import BridgeIPCMacOS
import Foundation

final class BridgeServiceXPCAdapter: NSObject, CodexBridgeServiceXPCProtocol,
  @unchecked Sendable
{
  let controller: BridgeServiceXPCController

  init(controller: BridgeServiceXPCController) {
    self.controller = controller
    super.init()
  }

  func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    controller.perform(request, withReply: reply)
  }
}

final class BridgeServiceXPCStreamSink: BridgeServiceIPCStreamSink, @unchecked Sendable {
  private let listener: CodexBridgeTaskStreamListener

  init(listener: CodexBridgeTaskStreamListener) {
    self.listener = listener
  }

  func push(_ payload: Data) {
    listener.push(payload)
  }
}
