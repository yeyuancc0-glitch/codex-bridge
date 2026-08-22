import Foundation

public protocol PlatformEnvironmentProviding: Sendable {
  var processArchitecture: PlatformArchitecture { get }
  var nativeOSArchitecture: PlatformArchitecture { get }
}

public struct PlatformComponentArchitecture: Codable, Equatable, Hashable, Sendable {
  public let component: String
  public let architecture: PlatformArchitecture

  public init(component: String, architecture: PlatformArchitecture) {
    self.component = component
    self.architecture = architecture
  }
}

public struct PlatformDiagnostics: Codable, Equatable, Hashable, Sendable {
  public static let processArchKey = "process_arch"
  public static let nativeOSArchKey = "native_os_arch"
  public static let codexArchKey = "codex_arch"
  public static let appServerArchKey = "app_server_arch"
  public static let tunnelArchKey = "tunnel_arch"
  public static let webView2ArchKey = "webview2_arch"

  public private(set) var values: [String: PlatformArchitecture]

  public init(
    environment: PlatformEnvironmentProviding,
    extraComponents: [String: PlatformArchitecture] = [:]
  ) {
    var values: [String: PlatformArchitecture] = [
      Self.processArchKey: environment.processArchitecture,
      Self.nativeOSArchKey: environment.nativeOSArchitecture,
      Self.codexArchKey: .unknown,
      Self.appServerArchKey: .unknown,
      Self.tunnelArchKey: .unknown,
      Self.webView2ArchKey: .unknown,
    ]
    for (key, architecture) in extraComponents where Self.knownKeys.contains(key) {
      values[key] = architecture
    }
    self.values = values
  }

  public func architecture(forKey key: String) -> PlatformArchitecture? {
    values[key]
  }

  public mutating func setArchitecture(
    forKey key: String,
    architecture: PlatformArchitecture
  ) {
    guard Self.knownKeys.contains(key) else { return }
    values[key] = architecture
  }

  public func mismatchedRequiredComponents(
    requiring requiredKeysAndArchitectures: [String: PlatformArchitecture]
  ) -> [String] {
    requiredKeysAndArchitectures.compactMap { key, required in
      guard let actual = values[key], actual != .unknown else { return nil }
      return actual == required ? nil : "\(key)=\(actual.rawValue) expected \(required.rawValue)"
    }
  }

  private static let knownKeys: Set<String> = [
    processArchKey,
    nativeOSArchKey,
    codexArchKey,
    appServerArchKey,
    tunnelArchKey,
    webView2ArchKey,
  ]
}
