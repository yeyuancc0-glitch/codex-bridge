import Foundation

public protocol BridgeServiceIPCStreamSink: Sendable {
  func push(_ payload: Data)
}
