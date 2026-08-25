import Foundation

public struct IPCAgentProviderSummary: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let adapterRevision: Int

  public init(providerID: String, displayName: String, adapterRevision: Int) {
    self.providerID = providerID
    self.displayName = displayName
    self.adapterRevision = adapterRevision
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case adapterRevision = "adapter_revision"
  }
}

public struct IPCAgentInstallationSummary: Codable, Equatable, Sendable {
  public let installationID: String
  public let providerID: String
  public let displayName: String
  public let executablePath: String
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let trustProfile: String
  public let securityProfileID: String?
  public let isEnabled: Bool
  public let availability: String
  public let effectiveCapabilities: [String]
  public let lastProbeError: String?
  public let lastProbedAt: String?
  public let updatedAt: String

  public init(
    installationID: String,
    providerID: String,
    displayName: String,
    executablePath: String,
    version: String? = nil,
    protocolRevision: String? = nil,
    adapterRevision: Int,
    trustProfile: String,
    securityProfileID: String? = nil,
    isEnabled: Bool,
    availability: String,
    effectiveCapabilities: [String],
    lastProbeError: String? = nil,
    lastProbedAt: String? = nil,
    updatedAt: String
  ) {
    self.installationID = installationID
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.isEnabled = isEnabled
    self.availability = availability
    self.effectiveCapabilities = effectiveCapabilities
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case providerID = "provider_id"
    case displayName = "display_name"
    case executablePath = "executable_path"
    case version
    case protocolRevision = "protocol_revision"
    case adapterRevision = "adapter_revision"
    case trustProfile = "trust_profile"
    case securityProfileID = "security_profile_id"
    case isEnabled = "is_enabled"
    case availability
    case effectiveCapabilities = "effective_capabilities"
    case lastProbeError = "last_probe_error"
    case lastProbedAt = "last_probed_at"
    case updatedAt = "updated_at"
  }
}

public struct IPCAgentCatalogResponse: Codable, Equatable, Sendable {
  public let providers: [IPCAgentProviderSummary]
  public let installations: [IPCAgentInstallationSummary]

  public init(
    providers: [IPCAgentProviderSummary],
    installations: [IPCAgentInstallationSummary]
  ) {
    self.providers = providers
    self.installations = installations
  }
}

public struct IPCAgentRegistrationRequest: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let executablePath: String

  public init(providerID: String, displayName: String, executablePath: String) {
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case executablePath = "executable_path"
  }
}

public struct IPCAgentReprobeRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let acceptReplacement: Bool

  public init(installationID: String, acceptReplacement: Bool = false) {
    self.installationID = installationID
    self.acceptReplacement = acceptReplacement
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case acceptReplacement = "accept_replacement"
  }
}

public struct IPCAgentEnabledRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let enabled: Bool

  public init(installationID: String, enabled: Bool) {
    self.installationID = installationID
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case enabled
  }
}

public struct IPCAgentInstallationIDRequest: Codable, Equatable, Sendable {
  public let installationID: String

  public init(installationID: String) {
    self.installationID = installationID
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
  }
}
