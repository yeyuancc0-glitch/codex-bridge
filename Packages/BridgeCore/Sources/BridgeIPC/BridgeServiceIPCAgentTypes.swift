import Foundation

public struct IPCAgentProviderSummary: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let adapterRevision: Int
  public let requiresConfiguration: Bool
  public let registrationTrustProfile: String
  public let supportsModelSelection: Bool
  public let supportsEffortSelection: Bool
  public let supportsSessionContinuation: Bool
  public let supportsSteer: Bool
  public let supportsWorkspaceWrite: Bool
  public let supportsSkillSelection: Bool
  public let supportsSupervisor: Bool
  public let workspaceEnforcement: String
  public let approvalEnforcement: String
  public let networkEnforcement: String

  public init(
    providerID: String,
    displayName: String,
    adapterRevision: Int,
    requiresConfiguration: Bool = false,
    registrationTrustProfile: String = "managed",
    supportsModelSelection: Bool = true,
    supportsEffortSelection: Bool = true,
    supportsSessionContinuation: Bool = true,
    supportsSteer: Bool = false,
    supportsWorkspaceWrite: Bool = true,
    supportsSkillSelection: Bool = false,
    supportsSupervisor: Bool = false,
    workspaceEnforcement: String = "legacy",
    approvalEnforcement: String = "legacy",
    networkEnforcement: String = "legacy"
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.adapterRevision = adapterRevision
    self.requiresConfiguration = requiresConfiguration
    self.registrationTrustProfile = registrationTrustProfile
    self.supportsModelSelection = supportsModelSelection
    self.supportsEffortSelection = supportsEffortSelection
    self.supportsSessionContinuation = supportsSessionContinuation
    self.supportsSteer = supportsSteer
    self.supportsWorkspaceWrite = supportsWorkspaceWrite
    self.supportsSkillSelection = supportsSkillSelection
    self.supportsSupervisor = supportsSupervisor
    self.workspaceEnforcement = workspaceEnforcement
    self.approvalEnforcement = approvalEnforcement
    self.networkEnforcement = networkEnforcement
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case adapterRevision = "adapter_revision"
    case requiresConfiguration = "requires_configuration"
    case registrationTrustProfile = "registration_trust_profile"
    case supportsModelSelection = "supports_model_selection"
    case supportsEffortSelection = "supports_effort_selection"
    case supportsSessionContinuation = "supports_session_continuation"
    case supportsSteer = "supports_steer"
    case supportsWorkspaceWrite = "supports_workspace_write"
    case supportsSkillSelection = "supports_skill_selection"
    case supportsSupervisor = "supports_supervisor"
    case workspaceEnforcement = "workspace_enforcement"
    case approvalEnforcement = "approval_enforcement"
    case networkEnforcement = "network_enforcement"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      providerID: try container.decode(String.self, forKey: .providerID),
      displayName: try container.decode(String.self, forKey: .displayName),
      adapterRevision: try container.decode(Int.self, forKey: .adapterRevision),
      requiresConfiguration: try container.decodeIfPresent(
        Bool.self,
        forKey: .requiresConfiguration
      ) ?? false,
      registrationTrustProfile: try container.decodeIfPresent(
        String.self,
        forKey: .registrationTrustProfile
      ) ?? "managed",
      supportsModelSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsModelSelection
      ) ?? true,
      supportsEffortSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsEffortSelection
      ) ?? true,
      supportsSessionContinuation: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSessionContinuation
      ) ?? true,
      supportsSteer: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSteer
      ) ?? false,
      supportsWorkspaceWrite: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsWorkspaceWrite
      ) ?? true,
      supportsSkillSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSkillSelection
      ) ?? false,
      supportsSupervisor: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSupervisor
      ) ?? false,
      workspaceEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .workspaceEnforcement
      ) ?? "legacy",
      approvalEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .approvalEnforcement
      ) ?? "legacy",
      networkEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .networkEnforcement
      ) ?? "legacy"
    )
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
  public let configurationPath: String?

  public init(
    providerID: String,
    displayName: String,
    executablePath: String,
    configurationPath: String? = nil
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.configurationPath = configurationPath
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case executablePath = "executable_path"
    case configurationPath = "configuration_path"
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

public struct IPCAgentSubmitRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let providerID: String
  public let installationID: String?
  public let model: String?
  public let effort: String?
  public let permissionMode: String?
  public let prompt: String
  public let threadID: String?
  public let skillName: String?
  public let networkAccess: Bool?
  public let modelOverride: Bool?
  public let permissionModeOverride: Bool?
  public let acceptanceCriteria: [String]?
  public let clientRequestID: String?

  public init(
    projectID: String,
    providerID: String,
    installationID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String? = nil,
    prompt: String,
    threadID: String? = nil,
    skillName: String? = nil,
    networkAccess: Bool? = nil,
    modelOverride: Bool? = nil,
    permissionModeOverride: Bool? = nil,
    acceptanceCriteria: [String]? = nil,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.providerID = providerID
    self.installationID = installationID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.prompt = prompt
    self.threadID = threadID
    self.skillName = skillName
    self.networkAccess = networkAccess
    self.modelOverride = modelOverride
    self.permissionModeOverride = permissionModeOverride
    self.acceptanceCriteria = acceptanceCriteria
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case providerID = "provider_id"
    case installationID = "installation_id"
    case model
    case effort
    case permissionMode = "permission_mode"
    case prompt
    case threadID = "thread_id"
    case skillName = "skill_name"
    case networkAccess = "network_access"
    case modelOverride = "model_override"
    case permissionModeOverride = "permission_mode_override"
    case acceptanceCriteria = "acceptance_criteria"
    case clientRequestID = "client_request_id"
  }
}

public struct IPCAgentSubmitResponse: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String

  public init(taskID: String, status: String) {
    self.taskID = taskID
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
  }
}

public struct IPCAgentModelsRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let projectID: String?
  public let modelID: String?
  public let useStoredDefault: Bool?

  public init(
    installationID: String,
    projectID: String? = nil,
    modelID: String? = nil,
    useStoredDefault: Bool? = nil
  ) {
    self.installationID = installationID
    self.projectID = projectID
    self.modelID = modelID
    self.useStoredDefault = useStoredDefault
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case projectID = "project_id"
    case modelID = "model_id"
    case useStoredDefault = "use_stored_default"
  }
}

public struct IPCAgentModelSummary: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let supportedReasoningEfforts: [String]
  public let defaultReasoningEffort: String?

  public init(
    modelID: String,
    displayName: String,
    supportedReasoningEfforts: [String] = [],
    defaultReasoningEffort: String? = nil
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
  }

  private enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case displayName = "display_name"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
    case defaultReasoningEffort = "default_reasoning_effort"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      modelID: try container.decode(String.self, forKey: .modelID),
      displayName: try container.decode(String.self, forKey: .displayName),
      supportedReasoningEfforts: try container.decodeIfPresent(
        [String].self,
        forKey: .supportedReasoningEfforts
      ) ?? [],
      defaultReasoningEffort: try container.decodeIfPresent(
        String.self,
        forKey: .defaultReasoningEffort
      )
    )
  }
}

public struct IPCAgentModelsResponse: Codable, Equatable, Sendable {
  public let models: [IPCAgentModelSummary]

  public init(models: [IPCAgentModelSummary]) {
    self.models = models
  }
}

public struct IPCAgentModelDefaultResponse: Codable, Equatable, Sendable {
  public let providerID: String
  public let model: String?
  public let permissionMode: String
  public let effort: String?

  public init(
    providerID: String = "opencode",
    model: String?,
    permissionMode: String = "build",
    effort: String? = nil
  ) {
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.effort = effort
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case model
    case permissionMode = "permission_mode"
    case effort
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      providerID: try container.decodeIfPresent(String.self, forKey: .providerID) ?? "opencode",
      model: try container.decodeIfPresent(String.self, forKey: .model),
      permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode)
        ?? "build",
      effort: try container.decodeIfPresent(String.self, forKey: .effort)
    )
  }
}

public struct IPCAgentModelDefaultRequest: Codable, Equatable, Sendable {
  public let providerID: String?
  public let model: String?
  public let permissionMode: String?
  public let effort: String?

  public init(
    providerID: String? = nil,
    model: String?,
    permissionMode: String? = nil,
    effort: String? = nil
  ) {
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.effort = effort
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case model
    case permissionMode = "permission_mode"
    case effort
  }
}
