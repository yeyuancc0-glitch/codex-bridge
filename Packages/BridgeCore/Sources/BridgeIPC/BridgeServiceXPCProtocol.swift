import Foundation

#if canImport(Darwin)
@objc public protocol CodexBridgeServiceXPCProtocol {
  func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol CodexBridgeTaskStreamListener {
  func push(_ payload: Data)
}
#else
public protocol CodexBridgeServiceXPCProtocol {
  func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public protocol CodexBridgeTaskStreamListener {
  func push(_ payload: Data)
}
#endif


