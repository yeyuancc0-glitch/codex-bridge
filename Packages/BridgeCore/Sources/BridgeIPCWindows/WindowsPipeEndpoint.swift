#if canImport(WinSDK)
  import BridgeIPC
  import BridgePlatformWindows
  import Foundation

  public enum WindowsPipeEndpointError: Error, Equatable, Sendable {
    case userIdentityUnavailable
  }

  public enum WindowsPipeEndpoint {
    public static func currentUserIdentifier() throws -> String {
      guard let sid = WindowsSecurity.currentUserSIDString()?.value,
        sid.hasPrefix("S-1-"),
        sid.utf8.count <= 184,
        sid.utf8.allSatisfy({ byte in
          (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "-")
        })
      else {
        throw WindowsPipeEndpointError.userIdentityUnavailable
      }
      return sid
    }

    public static func currentUserPipeName() throws -> String {
      "\(BridgeServiceIPC.windowsPipeBaseName).\(try currentUserIdentifier())"
    }

    public static func currentUserPath() throws -> String {
      "\\\\.\\pipe\\\(try currentUserPipeName())"
    }
  }
#endif
