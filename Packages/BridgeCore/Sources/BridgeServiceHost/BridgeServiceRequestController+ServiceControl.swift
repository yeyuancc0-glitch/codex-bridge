import BridgeIPC
import Foundation

#if os(Windows)
  import WinSDK
#endif

extension BridgeServiceRequestController {
  #if os(Windows)
    func handleShutdownService(_ request: BridgeServiceIPCRequest) throws -> Data {
      guard request.payload == nil else {
        throw BridgeServiceIPCCodecError.invalidMessage
      }
      let imagePath = try WindowsProcessIdentity.currentImagePath()
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID,
        payload: IPCServiceShutdownResponse(
          processID: GetCurrentProcessId(),
          imagePath: imagePath
        )
      )
    }
  #endif
}
