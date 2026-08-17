import Foundation

@objc public protocol CodexBridgeServiceXPCProtocol {
  func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum BridgeServiceIPC {
  public static let machServiceName = "org.codexbridge.service"
  public static let launchAgentPlistName = "org.codexbridge.service.plist"
  public static let schemaVersion = 1
  public static let maximumMessageBytes = 1 * 1_024 * 1_024
}
