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
  public let admission: MCPClientAdmissionGate

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
      authenticator: MCPClientCredentialAuthenticator(credentials: credentials),
      admission: MCPClientAdmissionGate()
    )
    try await registry.refreshCredentials()
    return registry
  }

  private init(
    settings: ServiceSettings,
    secrets: ServiceMCPSecretProvider,
    authenticator: MCPClientCredentialAuthenticator,
    admission: MCPClientAdmissionGate
  ) throws {
    self.settings = settings
    self.secrets = secrets
    self.authenticator = authenticator
    self.admission = admission
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
        enabled: try await settings.qwenStudioEnabled()
          && admission.isEnabled(.qwenStudio),
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
    admission.revoke(.qwenStudio)
    if enabled {
      do {
        try await installCredentials(qwenEnabled: false)
        let credentials = try await credentials(qwenEnabled: true)
        try await settings.setQwenStudioEnabled(true)
        try authenticator.replaceCredentials(credentials)
        admission.allow(.qwenStudio)
      } catch {
        try? await settings.setQwenStudioEnabled(false)
        try? await installCredentials(qwenEnabled: false)
        throw error
      }
      return
    }

    var firstError: (any Error)?
    do {
      try await settings.setQwenStudioEnabled(false)
    } catch {
      firstError = error
    }
    do {
      try await installCredentials(qwenEnabled: false)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await settings.setQwenStudioExposureMode(Self.serviceMode(mode))
  }

  public func rotateQwenStudioCredential() async throws {
    admission.revoke(.qwenStudio)
    let wasEnabled = try await settings.qwenStudioEnabled()
    do {
      try await installCredentials(qwenEnabled: false)
      _ = try await secrets.rotate(clientID: .qwenStudio)
      if wasEnabled {
        try await installCredentials(qwenEnabled: true)
        admission.allow(.qwenStudio)
      }
    } catch {
      if wasEnabled {
        try? await settings.setQwenStudioEnabled(false)
      }
      try? await installCredentials(qwenEnabled: false)
      throw error
    }
  }

  public func qwenStudioCredential() async throws -> String {
    guard try await settings.qwenStudioEnabled(), admission.isEnabled(.qwenStudio) else {
      throw ServiceMCPClientRegistryError.clientDisabled
    }
    return try await secrets.secret(for: .qwenStudio)
  }

  public func chatGPTCredential() async throws -> String {
    try await secrets.secret(for: .chatGPT)
  }

  private func refreshCredentials() async throws {
    let qwenEnabled = try await settings.qwenStudioEnabled()
    try await installCredentials(qwenEnabled: qwenEnabled)
    if qwenEnabled {
      admission.allow(.qwenStudio)
    } else {
      admission.revoke(.qwenStudio)
    }
  }

  private func installCredentials(qwenEnabled: Bool) async throws {
    try authenticator.replaceCredentials(try await credentials(qwenEnabled: qwenEnabled))
  }

  private func credentials(qwenEnabled: Bool) async throws -> [MCPClientCredential] {
    var credentials = [
      try MCPClientCredential(
        clientID: .chatGPT,
        value: try await secrets.secret(for: .chatGPT)
      )
    ]
    if qwenEnabled {
      credentials.append(
        try MCPClientCredential(
          clientID: .qwenStudio,
          value: try await secrets.secret(for: .qwenStudio)
        )
      )
    }
    return credentials
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
