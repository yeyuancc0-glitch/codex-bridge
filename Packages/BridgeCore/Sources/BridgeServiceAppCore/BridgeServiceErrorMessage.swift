import BridgeIPC
import Foundation

public enum BridgeServiceErrorMessage {
  /// Renders a user-facing message for IPC transport and remote errors.
  public static func message(_ error: any Error) -> String {
    if case .remoteError(let remote) = error as? BridgeServiceIPCCodecError {
      return remote.message
    }
    if let codec = error as? BridgeServiceIPCCodecError {
      switch codec {
      case .requestMismatch:
        return "后台 Service 与本 App 的 IPC 版本不一致，请重新注册或重启后台 Service。"
      case .unsupportedSchemaVersion:
        return "后台 Service 与本 App 的 IPC 版本不一致，请重新注册或重启后台 Service。"
      default:
        break
      }
    }
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return error.localizedDescription
  }
}
