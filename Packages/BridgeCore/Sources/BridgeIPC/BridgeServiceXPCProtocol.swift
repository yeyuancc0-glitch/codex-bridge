import Foundation

#if os(macOS)
  @objc public protocol CodexBridgeServiceXPCProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
  }

  @objc public protocol CodexBridgeTaskStreamListener {
    func push(_ payload: Data)
  }
#endif

public enum BridgeServiceIPC {
  public static let machServiceName = "org.codexbridge.service"
  public static let launchAgentPlistName = "org.codexbridge.service.plist"
  public static let schemaVersion = 4
  public static let maximumMessageBytes = 8 * 1_024 * 1_024
}
