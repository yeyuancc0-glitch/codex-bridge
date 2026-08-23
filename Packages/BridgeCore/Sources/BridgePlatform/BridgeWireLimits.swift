import Foundation

/// Wire limits shared by every transport that carries bridge messages.
/// The 8 MiB ceiling matches `BridgeServiceIPC.maximumMessageBytes`; the
/// constant lives here so platform transports can enforce it without
/// depending on the macOS-side IPC DTO module.
public enum BridgeWireLimits {
  public static let maximumMessageBytes = 8 * 1_024 * 1_024
}
