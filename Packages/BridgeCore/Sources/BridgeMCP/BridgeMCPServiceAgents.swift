import Foundation

public struct MCPAgentSummary: Codable, Equatable, Sendable {
  public let providerID: String
  public let installationID: String
  public let displayName: String
  public let availability: String
  public let enabled: Bool
  public let taskSubmissionEnabled: Bool
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let effectiveCapabilities: [String]
  public let trustProfile: String
  public let securityProfileID: String?
  public let workspaceEnforcement: String
  public let approvalEnforcement: String
  public let networkEnforcement: String
  public let modelsSummary: [String]
  public let unavailableReason: String?
  public let lastVerifiedAt: String?

  public init(
    providerID: String,
    installationID: String,
    displayName: String,
    availability: String,
    enabled: Bool,
    taskSubmissionEnabled: Bool,
    version: String?,
    protocolRevision: String?,
    adapterRevision: Int,
    effectiveCapabilities: [String],
    trustProfile: String,
    securityProfileID: String?,
    workspaceEnforcement: String,
    approvalEnforcement: String,
    networkEnforcement: String,
    modelsSummary: [String],
    unavailableReason: String?,
    lastVerifiedAt: String?
  ) {
    self.providerID = providerID
    self.installationID = installationID
    self.displayName = displayName
    self.availability = availability
    self.enabled = enabled
    self.taskSubmissionEnabled = taskSubmissionEnabled
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.effectiveCapabilities = effectiveCapabilities
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.workspaceEnforcement = workspaceEnforcement
    self.approvalEnforcement = approvalEnforcement
    self.networkEnforcement = networkEnforcement
    self.modelsSummary = modelsSummary
    self.unavailableReason = unavailableReason
    self.lastVerifiedAt = lastVerifiedAt
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case installationID = "installation_id"
    case displayName = "display_name"
    case availability
    case enabled
    case taskSubmissionEnabled = "task_submission_enabled"
    case version
    case protocolRevision = "protocol_revision"
    case adapterRevision = "adapter_revision"
    case effectiveCapabilities = "effective_capabilities"
    case trustProfile = "trust_profile"
    case securityProfileID = "security_profile_id"
    case workspaceEnforcement = "workspace_enforcement"
    case approvalEnforcement = "approval_enforcement"
    case networkEnforcement = "network_enforcement"
    case modelsSummary = "models_summary"
    case unavailableReason = "unavailable_reason"
    case lastVerifiedAt = "last_verified_at"
  }
}

public struct MCPAgentList: Codable, Equatable, Sendable {
  public let agents: [MCPAgentSummary]

  public init(agents: [MCPAgentSummary]) {
    self.agents = agents
  }
}
