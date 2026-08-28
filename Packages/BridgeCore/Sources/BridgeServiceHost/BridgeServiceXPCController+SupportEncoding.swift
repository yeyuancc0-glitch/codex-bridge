import BridgeIPC
import Foundation

extension BridgeServiceXPCController {
  static func deadline() -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: .seconds(20))
  }

  static func fallbackFailure(
    requestID: String,
    code: String,
    message: String,
    retryable: Bool = false
  ) -> Data {
    if let response = try? BridgeServiceIPCCodec.failure(
      requestID: requestID,
      error: .init(code: code, message: message, retryable: retryable)
    ) {
      return response
    }
    let fallback =
      #"{"schema_version":1,"request_id":"invalid","payload":null,"error":{"#
      + #""code":"internal_error","message":"The service failed.","retryable":true}}"#
    return Data(fallback.utf8)
  }
}
