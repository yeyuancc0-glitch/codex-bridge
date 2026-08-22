import Foundation

public enum PlatformArchitecture: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
  case amd64 = "x86_64"
  case arm64
  case unknown

  public init(target: () -> PlatformArchitecture) {
    self = target()
  }
}

public enum TargetPlatformArchitecture {
  public static var current: PlatformArchitecture {
    #if arch(x86_64)
      return .amd64
    #elseif arch(arm64)
      return .arm64
    #else
      return .unknown
    #endif
  }
}
