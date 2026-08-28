import BridgeAgentCore
import Foundation

public struct ServiceAgentInstallationRecord: Codable, Equatable, Sendable {
  public let id: AgentInstallationID
  public let providerID: AgentProviderID
  public let displayName: String
  public let executablePath: String
  public let executableIdentity: ServiceAgentExecutableIdentity
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let trustProfile: AgentTrustProfile
  public let securityProfileID: AgentProfileID?
  public let isEnabled: Bool
  public let availability: ServiceAgentInstallationAvailability
  public let capabilities: AgentCapabilitySnapshot
  public let artifacts: [ServiceAgentInstallationArtifact]
  public let lastProbeError: String?
  public let lastProbedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date

  public var isSelectable: Bool {
    isEnabled && availability == .available
  }

  public init(
    id: AgentInstallationID,
    providerID: AgentProviderID,
    displayName: String,
    executablePath: String,
    executableIdentity: ServiceAgentExecutableIdentity,
    version: String?,
    protocolRevision: String?,
    adapterRevision: Int,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID?,
    isEnabled: Bool,
    availability: ServiceAgentInstallationAvailability,
    capabilities: AgentCapabilitySnapshot,
    artifacts: [ServiceAgentInstallationArtifact] = [],
    lastProbeError: String? = nil,
    lastProbedAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.identifier(
      id.rawValue,
      field: "agentInstallation.id",
      maximumBytes: 256
    )
    try ServiceValidation.identifier(
      providerID.rawValue,
      field: "agentInstallation.providerID",
      maximumBytes: 128
    )
    try ServiceValidation.text(
      displayName,
      field: "agentInstallation.displayName",
      maximumBytes: 256
    )
    guard executablePath.hasPrefix("/"),
      executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0"),
      executablePath.rangeOfCharacter(from: .controlCharacters) == nil,
      adapterRevision > 0
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    if let version {
      try ServiceValidation.identifier(
        version,
        field: "agentInstallation.version",
        maximumBytes: 256
      )
    }
    if let protocolRevision {
      try ServiceValidation.identifier(
        protocolRevision,
        field: "agentInstallation.protocolRevision",
        maximumBytes: 128
      )
    }
    if let securityProfileID {
      try ServiceValidation.identifier(
        securityProfileID.rawValue,
        field: "agentInstallation.securityProfileID",
        maximumBytes: 256
      )
    }
    try ServiceValidation.optionalText(
      lastProbeError,
      field: "agentInstallation.lastProbeError",
      maximumBytes: 4 * 1_024
    )
    try ServiceValidation.date(createdAt, field: "agentInstallation.createdAt")
    try ServiceValidation.date(updatedAt, field: "agentInstallation.updatedAt")
    if let lastProbedAt {
      try ServiceValidation.date(lastProbedAt, field: "agentInstallation.lastProbedAt")
    }
    guard updatedAt >= createdAt,
      lastProbedAt.map({ $0 >= createdAt && $0 <= updatedAt }) ?? true
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.timestamps")
    }
    if availability == .available {
      guard version != nil, lastProbedAt != nil, lastProbeError == nil else {
        throw ServiceStoreError.invalidArgument("agentInstallation.availableState")
      }
    } else {
      guard capabilities == .empty else {
        throw ServiceStoreError.invalidArgument("agentInstallation.capabilities")
      }
    }
    guard artifacts.count <= ServiceAgentInstallationArtifact.maximumCount,
      Set(artifacts.map(\.role)).count == artifacts.count
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifacts")
    }
    self.id = id
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.executableIdentity = executableIdentity
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.isEnabled = isEnabled
    self.availability = availability
    self.capabilities = capabilities
    self.artifacts = artifacts.sorted { $0.role.rawValue < $1.role.rawValue }
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case providerID
    case displayName
    case executablePath
    case executableIdentity
    case version
    case protocolRevision
    case adapterRevision
    case trustProfile
    case securityProfileID
    case isEnabled
    case availability
    case capabilities
    case artifacts
    case lastProbeError
    case lastProbedAt
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(AgentInstallationID.self, forKey: .id),
      providerID: container.decode(AgentProviderID.self, forKey: .providerID),
      displayName: container.decode(String.self, forKey: .displayName),
      executablePath: container.decode(String.self, forKey: .executablePath),
      executableIdentity: container.decode(
        ServiceAgentExecutableIdentity.self,
        forKey: .executableIdentity
      ),
      version: container.decodeIfPresent(String.self, forKey: .version),
      protocolRevision: container.decodeIfPresent(String.self, forKey: .protocolRevision),
      adapterRevision: container.decode(Int.self, forKey: .adapterRevision),
      trustProfile: container.decode(AgentTrustProfile.self, forKey: .trustProfile),
      securityProfileID: container.decodeIfPresent(AgentProfileID.self, forKey: .securityProfileID),
      isEnabled: container.decode(Bool.self, forKey: .isEnabled),
      availability: container.decode(
        ServiceAgentInstallationAvailability.self,
        forKey: .availability
      ),
      capabilities: container.decode(AgentCapabilitySnapshot.self, forKey: .capabilities),
      artifacts: container.decodeIfPresent(
        [ServiceAgentInstallationArtifact].self,
        forKey: .artifacts
      ) ?? [],
      lastProbeError: container.decodeIfPresent(String.self, forKey: .lastProbeError),
      lastProbedAt: container.decodeIfPresent(Date.self, forKey: .lastProbedAt),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func agentInstallation() throws -> AgentInstallation {
    try AgentInstallation(
      id: id,
      providerID: providerID,
      executablePath: executableIdentity.canonicalPath,
      version: version,
      protocolRevision: protocolRevision,
      artifacts: artifacts.map { artifact in
        AgentInstallationArtifact(
          role: artifact.role,
          canonicalPath: artifact.identity.canonicalPath,
          device: artifact.identity.device,
          inode: artifact.identity.inode,
          fileSize: artifact.identity.fileSize,
          modificationTimeNanoseconds: artifact.identity.modificationTimeNanoseconds,
          sha256: artifact.identity.sha256
        )
      }
    )
  }

  public func replacingEnabled(_ enabled: Bool, updatedAt: Date) throws
    -> ServiceAgentInstallationRecord
  {
    try ServiceAgentInstallationRecord(
      id: id,
      providerID: providerID,
      displayName: displayName,
      executablePath: executablePath,
      executableIdentity: executableIdentity,
      version: version,
      protocolRevision: protocolRevision,
      adapterRevision: adapterRevision,
      trustProfile: trustProfile,
      securityProfileID: securityProfileID,
      isEnabled: enabled,
      availability: availability,
      capabilities: capabilities,
      artifacts: artifacts,
      lastProbeError: lastProbeError,
      lastProbedAt: lastProbedAt,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
