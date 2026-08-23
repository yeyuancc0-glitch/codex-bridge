import BridgeSecurity
import BridgeTunnel
import Foundation

public struct ServiceTunnelSnapshot: Equatable, Sendable {
  public let configured: Bool
  public let enabled: Bool
  public let helperAvailable: Bool
  public let tunnelID: String?
  public let lifecycle: TunnelLifecycle
  public let acceptsRemoteSubmissions: Bool
  public let actionRequired: Bool

  public init(
    configured: Bool,
    enabled: Bool,
    helperAvailable: Bool,
    tunnelID: String?,
    lifecycle: TunnelLifecycle,
    acceptsRemoteSubmissions: Bool,
    actionRequired: Bool
  ) {
    self.configured = configured
    self.enabled = enabled
    self.helperAvailable = helperAvailable
    self.tunnelID = tunnelID
    self.lifecycle = lifecycle
    self.acceptsRemoteSubmissions = acceptsRemoteSubmissions
    self.actionRequired = actionRequired
  }

  public static func unconfigured(helperAvailable: Bool) -> ServiceTunnelSnapshot {
    ServiceTunnelSnapshot(
      configured: false,
      enabled: false,
      helperAvailable: helperAvailable,
      tunnelID: nil,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false
    )
  }
}

public enum ServiceTunnelError: Error, Equatable, LocalizedError, Sendable {
  case invalidRuntimeKey
  case notConfigured
  case localMCPUnavailable
  case helperUnavailable
  case invalidStoredConfiguration
  case secretStoreUnavailable
  case serviceStopped
  case startFailed

  public var errorDescription: String? {
    switch self {
    case .invalidRuntimeKey:
      "The Tunnel Runtime Key is invalid."
    case .notConfigured:
      "Secure MCP Tunnel is not configured."
    case .localMCPUnavailable:
      "The local MCP endpoint is unavailable."
    case .helperUnavailable:
      "The signed tunnel-client helper is not available in this App build."
    case .invalidStoredConfiguration:
      "The stored Tunnel configuration is invalid."
    case .secretStoreUnavailable:
      "The Tunnel Runtime Key is unavailable in the platform credential store."
    case .serviceStopped:
      "The background Service is stopping."
    case .startFailed:
      "Secure MCP Tunnel could not start."
    }
  }
}

public protocol ServiceTunnelManaging: Sendable {
  func start() async throws
  func stop() async
  func state() async -> TunnelLifecycle
  func acceptsRemoteSubmissions() async -> Bool
  func diagnostics() async -> TunnelDiagnostics
}

#if canImport(Darwin)
  extension TunnelManager: ServiceTunnelManaging {}
#endif

public protocol ServiceTunnelManagerBuilding: Sendable {
  func helperAvailable() -> Bool

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any ServiceTunnelManaging
}
