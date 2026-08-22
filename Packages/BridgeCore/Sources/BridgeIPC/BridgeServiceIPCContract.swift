import Foundation

public enum BridgeServiceIPC {
  public static let machServiceName = "org.codexbridge.service"
  public static let launchAgentPlistName = "org.codexbridge.service.plist"
  public static let schemaVersion = 3
  public static let maximumMessageBytes = 8 * 1_024 * 1_024
}
