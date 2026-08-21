import BridgeMCP
import BridgeServiceCore
import Foundation

public struct ServiceMCPClientProfile: Equatable, Sendable {
  public let clientID: MCPClientID
  public let displayName: String
  public let enabled: Bool
  public let exposureMode: MCPServiceExposureMode

  public init(
    clientID: MCPClientID,
    displayName: String,
    enabled: Bool,
    exposureMode: MCPServiceExposureMode
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.enabled = enabled
    self.exposureMode = exposureMode
  }
}

public enum ServiceMCPClientRegistryError: Error, Equatable, Sendable {
  case unsupportedClient
  case clientDisabled
}

public actor ServiceMCPClientRegistry {
  public let authenticator: MCPClientCredentialAuthenticator

  private let settings: ServiceSettings
  private let secrets: ServiceMCPSecretProvider

  public static func make(
    settings: ServiceSettings,
    secrets: ServiceMCPSecretProvider
  ) async throws -> ServiceMCPClientRegistry {
    let chatGPTSecret = try await secrets.secret(for: .chatGPT)
    let credentials = [
      try MCPClientCredential(clientID: .chatGPT, value: chatGPTSecret)
    ]
    let registry = try ServiceMCPClientRegistry(
      settings: settings,
      secrets: secrets,
      authenticator: MCPClientCredentialAuthenticator(credentials: credentials)
    )
    try await registry.refreshCredentials()
    return registry
  }

  private init(
    settings: ServiceSettings,
    secrets: ServiceMCPSecretProvider,
    authenticator: MCPClientCredentialAuthenticator
  ) throws {
    self.settings = settings
    self.secrets = secrets
    self.authenticator = authenticator
  }

  public func profiles() async throws -> [ServiceMCPClientProfile] {
    [
      ServiceMCPClientProfile(
        clientID: .chatGPT,
        displayName: "ChatGPT",
        enabled: true,
        exposureMode: Self.mcpMode(try await settings.exposureMode())
      ),
      ServiceMCPClientProfile(
        clientID: .qwenStudio,
        displayName: "Qwen Studio",
        enabled: try await settings.qwenStudioEnabled(),
        exposureMode: Self.mcpMode(try await settings.qwenStudioExposureMode())
      ),
    ]
  }

  public func exposureMode(for clientID: MCPClientID) async -> MCPServiceExposureMode {
    do {
      switch clientID {
      case .chatGPT:
        return Self.mcpMode(try await settings.exposureMode())
      case .qwenStudio:
        return Self.mcpMode(try await settings.qwenStudioExposureMode())
      default:
        return .readOnly
      }
    } catch {
      return .readOnly
    }
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    try await settings.setQwenStudioEnabled(enabled)
    try await refreshCredentials()
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await settings.setQwenStudioExposureMode(Self.serviceMode(mode))
  }

  public func rotateQwenStudioCredential() async throws {
    _ = try await secrets.rotate(clientID: .qwenStudio)
    try await refreshCredentials()
  }

  public func qwenStudioCredential() async throws -> String {
    guard try await settings.qwenStudioEnabled() else {
      throw ServiceMCPClientRegistryError.clientDisabled
    }
    return try await secrets.secret(for: .qwenStudio)
  }

  public func chatGPTCredential() async throws -> String {
    try await secrets.secret(for: .chatGPT)
  }

  private func refreshCredentials() async throws {
    var credentials = [
      try MCPClientCredential(
        clientID: .chatGPT,
        value: try await secrets.secret(for: .chatGPT)
      )
    ]
    if try await settings.qwenStudioEnabled() {
      credentials.append(
        try MCPClientCredential(
          clientID: .qwenStudio,
          value: try await secrets.secret(for: .qwenStudio)
        )
      )
    }
    try authenticator.replaceCredentials(credentials)
  }

  private static func mcpMode(_ mode: ServiceMCPExposureMode) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func serviceMode(_ mode: MCPServiceExposureMode) -> ServiceMCPExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }
}
