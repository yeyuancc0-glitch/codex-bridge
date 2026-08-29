import BridgeAgentCore
import BridgeServiceCore
import Foundation

/// The service-level contract for an agent provider.
///
/// Provider adapters report runtime capabilities, while this policy describes
/// the capabilities and controls that the service is willing to expose. The
/// intersection is applied at the service boundary so a newly registered
/// adapter cannot opt itself into a task shape that the service does not
/// support.
public struct ServiceAgentProviderPolicy: Equatable, Sendable {
  public let providerID: AgentProviderID
  public let displayName: String
  public let requiresInstallation: Bool
  public let requiresConfiguration: Bool
  public let supportsWorkspaceWrite: Bool
  public let supportsSessionContinuation: Bool
  public let supportsSteer: Bool
  public let supportsInteractiveApproval: Bool
  public let supportsModelSelection: Bool
  public let supportsEffortSelection: Bool
  public let supportsSkillSelection: Bool
  public let supportsSupervisor: Bool
  public let allowsNetworkAccess: Bool
  public let workspaceEnforcement: String
  public let approvalEnforcement: String
  public let networkEnforcement: String
  public let allowedCapabilities: Set<AgentCapability>?
  public let requiredArtifactRoles: Set<AgentInstallationArtifactRole>
  public let requiredVersion: String?
  public let requiredProtocolRevision: String?
  public let registrationTrustProfile: AgentTrustProfile
  public let registrationSecurityProfileID: AgentProfileID?
  public let requiresExactRegistrationProfile: Bool
  public let selectionsRequireObservedCapabilities: Bool

  public init(
    providerID: AgentProviderID,
    displayName: String,
    requiresInstallation: Bool = true,
    requiresConfiguration: Bool = false,
    supportsWorkspaceWrite: Bool = false,
    supportsSessionContinuation: Bool = false,
    supportsSteer: Bool = false,
    supportsInteractiveApproval: Bool = false,
    supportsModelSelection: Bool = false,
    supportsEffortSelection: Bool = false,
    supportsSkillSelection: Bool = false,
    supportsSupervisor: Bool = false,
    allowsNetworkAccess: Bool = false,
    workspaceEnforcement: String = "unavailable",
    approvalEnforcement: String = "unavailable",
    networkEnforcement: String = "unavailable",
    allowedCapabilities: Set<AgentCapability>? = nil,
    requiredArtifactRoles: Set<AgentInstallationArtifactRole> = [],
    requiredVersion: String? = nil,
    requiredProtocolRevision: String? = nil,
    registrationTrustProfile: AgentTrustProfile = .managed,
    registrationSecurityProfileID: AgentProfileID? = nil,
    requiresExactRegistrationProfile: Bool = false,
    selectionsRequireObservedCapabilities: Bool = false
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.requiresInstallation = requiresInstallation
    self.requiresConfiguration = requiresConfiguration
    self.supportsWorkspaceWrite = supportsWorkspaceWrite
    self.supportsSessionContinuation = supportsSessionContinuation
    self.supportsSteer = supportsSteer
    self.supportsInteractiveApproval = supportsInteractiveApproval
    self.supportsModelSelection = supportsModelSelection
    self.supportsEffortSelection = supportsEffortSelection
    self.supportsSkillSelection = supportsSkillSelection
    self.supportsSupervisor = supportsSupervisor
    self.allowsNetworkAccess = allowsNetworkAccess
    self.workspaceEnforcement = workspaceEnforcement
    self.approvalEnforcement = approvalEnforcement
    self.networkEnforcement = networkEnforcement
    self.allowedCapabilities = allowedCapabilities
    self.requiredArtifactRoles = requiredArtifactRoles
    self.requiredVersion = requiredVersion
    self.requiredProtocolRevision = requiredProtocolRevision
    self.registrationTrustProfile = registrationTrustProfile
    self.registrationSecurityProfileID = registrationSecurityProfileID
    self.requiresExactRegistrationProfile = requiresExactRegistrationProfile
    self.selectionsRequireObservedCapabilities = selectionsRequireObservedCapabilities
  }

  public func effectiveCapabilities(
    _ capabilities: Set<AgentCapability>,
    projectAllowsWorkspaceWrite: Bool
  ) -> Set<AgentCapability> {
    var result = allowedCapabilities.map { capabilities.intersection($0) } ?? capabilities
    if !supportsWorkspaceWrite || !projectAllowsWorkspaceWrite {
      result.remove(.workspaceWriteInPlace)
      result.remove(.workspaceWriteIsolated)
    }
    if !supportsSessionContinuation {
      result.remove(.sessionContinue)
    }
    if !supportsSteer {
      result.remove(.steer)
    }
    if !supportsInteractiveApproval {
      result.remove(.oneShotApproval)
      result.remove(.sessionRuleApproval)
      result.remove(.structuredApprovalPayload)
    }
    if !supportsModelSelection {
      result.remove(.modelSelection)
    }
    if !supportsEffortSelection {
      result.remove(.effortSelection)
    }
    return result
  }

  public func taskSubmissionEnabled(
    isSelectable: Bool,
    capabilities: Set<AgentCapability>,
    artifactRoles: Set<AgentInstallationArtifactRole>,
    version: String?,
    protocolRevision: String?
  ) -> Bool {
    requiresInstallation
      && isSelectable
      && capabilities.contains(.workspaceRead)
      && requiredArtifactRoles.isSubset(of: artifactRoles)
      && (requiredVersion == nil || version == requiredVersion)
      && (requiredProtocolRevision == nil || protocolRevision == requiredProtocolRevision)
  }

  public var defaultPermissionMode: ServicePermissionMode {
    supportsWorkspaceWrite ? .workspaceWrite : .readOnly
  }
}

/// The only service-owned provider policy registry. Adapter-specific modules
/// may expose richer protocol details, but task admission and presentation use
/// this table as the provider-neutral policy source of truth.
public enum ServiceAgentProviderPolicyRegistry {
  public static let controlledReadOnlyProfileID = AgentProfileID(
    rawValue: "controlled-readonly"
  )

  public static let codex = ServiceAgentProviderPolicy(
    providerID: .codex,
    displayName: "Codex",
    requiresInstallation: false,
    supportsWorkspaceWrite: true,
    supportsSessionContinuation: true,
    supportsSteer: true,
    supportsInteractiveApproval: true,
    supportsModelSelection: true,
    supportsEffortSelection: true,
    supportsSkillSelection: true,
    supportsSupervisor: true,
    allowsNetworkAccess: true,
    workspaceEnforcement: "bridge",
    approvalEnforcement: "local_app",
    networkEnforcement: "bridge"
  )

  public static let openCode = ServiceAgentProviderPolicy(
    providerID: .openCode,
    displayName: "OpenCode",
    supportsWorkspaceWrite: true,
    supportsSessionContinuation: true,
    supportsSteer: true,
    supportsInteractiveApproval: true,
    supportsModelSelection: true,
    supportsEffortSelection: true,
    supportsSkillSelection: true,
    allowsNetworkAccess: true,
    workspaceEnforcement: "provider_native",
    approvalEnforcement: "local_app",
    networkEnforcement: "provider_native",
    registrationSecurityProfileID: controlledReadOnlyProfileID
  )

  public static let deepSeekHarness = ServiceAgentProviderPolicy(
    providerID: .deepSeekHarness,
    displayName: "DeepSeek Harness",
    requiresConfiguration: true,
    supportsWorkspaceWrite: true,
    supportsSessionContinuation: false,
    supportsSteer: true,
    supportsInteractiveApproval: true,
    supportsModelSelection: true,
    supportsEffortSelection: true,
    supportsSkillSelection: true,
    supportsSupervisor: false,
    allowsNetworkAccess: true,
    workspaceEnforcement: "provider_native",
    approvalEnforcement: "local_app",
    networkEnforcement: "provider_native",
    allowedCapabilities: [
      .sessionCreate, .interrupt, .steer, .textDelta, .toolLifecycle, .workspaceRead,
      .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
      .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
      .skills,
    ],
    requiredArtifactRoles: Set(AgentInstallationArtifactRole.allCases),
    requiredVersion: "0.1.1-rc.2",
    requiredProtocolRevision: "1",
    registrationTrustProfile: .userTrusted,
    registrationSecurityProfileID: controlledReadOnlyProfileID,
    requiresExactRegistrationProfile: true
  )

  public static let antigravity = ServiceAgentProviderPolicy(
    providerID: .antigravity,
    displayName: "Antigravity",
    requiresInstallation: true,
    supportsWorkspaceWrite: true,
    supportsSessionContinuation: true,
    supportsSteer: true,
    supportsInteractiveApproval: false,
    supportsModelSelection: true,
    supportsEffortSelection: true,
    supportsSkillSelection: true,
    allowsNetworkAccess: true,
    workspaceEnforcement: "bridge_workspace_sandbox",
    approvalEnforcement: "provider_soft_deny",
    networkEnforcement: "provider_native",
    allowedCapabilities: [
      .sessionCreate, .interrupt, .steer, .toolLifecycle, .usage, .workspaceRead,
      .workspaceWriteInPlace, .sessionContinue, .modelSelection, .effortSelection, .shell,
      .webSearch, .webFetch, .mcpClient, .subagents, .childRuns,
    ],
    requiredArtifactRoles: [],
    registrationTrustProfile: .userTrusted,
    registrationSecurityProfileID: AgentProfileID(rawValue: "desktop-shared"),
    requiresExactRegistrationProfile: true,
    selectionsRequireObservedCapabilities: true
  )

  public static let all: [ServiceAgentProviderPolicy] =
    [codex, openCode, deepSeekHarness, antigravity]

  private static let byID: [AgentProviderID: ServiceAgentProviderPolicy] =
    Dictionary(uniqueKeysWithValues: all.map { ($0.providerID, $0) })

  public static func policy(for providerID: AgentProviderID) -> ServiceAgentProviderPolicy? {
    byID[providerID]
  }

  public static func policy(for rawProviderID: String) -> ServiceAgentProviderPolicy? {
    policy(for: AgentProviderID(rawValue: rawProviderID))
  }

  public static func displayName(for providerID: AgentProviderID) -> String {
    policy(for: providerID)?.displayName ?? providerID.rawValue
  }

  public static func registrationSecurityProfileID(
    for providerID: AgentProviderID
  ) -> AgentProfileID? {
    policy(for: providerID)?.registrationSecurityProfileID
  }
}
