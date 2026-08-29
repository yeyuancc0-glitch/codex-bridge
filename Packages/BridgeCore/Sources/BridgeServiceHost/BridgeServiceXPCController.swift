#if os(macOS)
  import BridgeIPC
  import Foundation

  /// XPC exporter that forwards NSXPC `perform` calls into the transport-
  /// neutral request controller.
  public final class BridgeServiceXPCController: NSObject,
    CodexBridgeServiceXPCProtocol, @unchecked Sendable
  {
    let controller: BridgeServiceRequestController

    var streams: StreamRegistry {
      controller.streams
    }

    public init(
      composition: ServiceComposition,
      streamProxy: (any ServiceStreamSink)? = nil,
      maximumConcurrentRequests: Int = 8
    ) {
      controller = BridgeServiceRequestController(
        composition: composition,
        streamSink: streamProxy,
        maximumConcurrentRequests: maximumConcurrentRequests
      )
      super.init()
    }

    public func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
      let replyBox = XPCReplyBox(reply)
      let controller = self.controller
      Task {
        replyBox.call(await controller.dispatch(request))
      }
    }

    public func stopStreaming() {
      controller.stopStreaming()
    }
  }
#endif
