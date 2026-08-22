import BridgePlatform
import Foundation

#if canImport(WinSDK)
  import WinSDK
#endif

public struct WindowsPlatformEnvironment: PlatformEnvironmentProviding {
  public init() {}

  public var processArchitecture: PlatformArchitecture {
    TargetPlatformArchitecture.current
  }

  public var nativeOSArchitecture: PlatformArchitecture {
    #if canImport(WinSDK)
      var processMachine: WORD = 0
      var nativeMachine: WORD = 0
      let succeeded = IsWow64Process2(
        GetCurrentProcess(),
        &processMachine,
        &nativeMachine
      )
      guard succeeded else {
        return processArchitecture
      }
      switch Int32(nativeMachine) {
      case IMAGE_FILE_MACHINE_ARM64:
        return .arm64
      case IMAGE_FILE_MACHINE_AMD64:
        return .amd64
      default:
        return .unknown
      }
    #else
      return .unknown
    #endif
  }
}
