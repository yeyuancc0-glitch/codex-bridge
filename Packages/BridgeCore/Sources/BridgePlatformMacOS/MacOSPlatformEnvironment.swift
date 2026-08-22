import BridgePlatform
import Foundation

public struct MacOSPlatformEnvironment: PlatformEnvironmentProviding {
  public init() {}

  public var processArchitecture: PlatformArchitecture {
    TargetPlatformArchitecture.current
  }

  public var nativeOSArchitecture: PlatformArchitecture {
    Self.machineArchitecture ?? processArchitecture
  }

  private static let machineArchitecture: PlatformArchitecture? = {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
    let machine = String(cString: buffer)
    if machine.hasPrefix("arm64") || machine.hasPrefix("aarch64") { return .arm64 }
    if machine.hasPrefix("x86_64") { return .amd64 }
    return nil
  }()
}
