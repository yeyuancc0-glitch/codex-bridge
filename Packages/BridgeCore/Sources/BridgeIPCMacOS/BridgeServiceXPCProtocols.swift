import Foundation

@objc public protocol CodexBridgeServiceXPCProtocol {
  func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol CodexBridgeTaskStreamListener {
  func push(_ payload: Data)
}
