import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceManagedAgentProviderDescriptors(
    deadline: ContinuousClock.Instant
  ) async throws -> [AgentProviderDescriptor] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().providerDescriptors()
  }

  public func serviceManagedAgentInstallations(
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentInstallationRecord] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().installations()
  }

  public func serviceRegisterManagedAgent(
    _ request: ServiceAgentRegistrationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    if let policy = ServiceAgentProviderPolicyRegistry.policy(for: request.providerID),
      policy.requiresConfiguration,
      request.configurationPath == nil,
      !request.artifacts.contains(where: { $0.role == .launchConfiguration })
    {
      throw BridgeMCPQueryError.contractRejected
    }
    if let policy = ServiceAgentProviderPolicyRegistry.policy(for: request.providerID),
      policy.requiresExactRegistrationProfile
    {
      guard request.trustProfile == policy.registrationTrustProfile,
        request.securityProfileID == policy.registrationSecurityProfileID,
        Set(request.artifactRequests.map(\.role)) == policy.requiredArtifactRoles
      else {
        throw BridgeMCPQueryError.contractRejected
      }
    }
    let record = try await requiredAgentRegistry().registerAndProbe(request)
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceReprobeManagedAgent(
    installationID: AgentInstallationID,
    acceptReplacement: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().reprobe(
      installationID: installationID,
      acceptReplacement: acceptReplacement
    )
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceSetManagedAgentEnabled(
    installationID: AgentInstallationID,
    enabled: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().setEnabled(
      enabled,
      installationID: installationID
    )
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceRemoveManagedAgent(
    installationID: AgentInstallationID,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await requiredAgentRegistry().remove(installationID: installationID)
  }

  func requiredAgentRegistry() throws -> ServiceAgentRegistry {
    guard let agentRegistry else { throw BridgeMCPQueryError.unavailable }
    return agentRegistry
  }
}

extension BridgeServiceApplication {
  /// Local App submission path for agent providers. Mirrors the MCP
  /// `submit_task` semantics: persists as awaiting_local_approval and never
  /// auto-starts.
  public func serviceSubmitAgentTask(
    projectID: String,
    providerID: String,
    installationID: String?,
    model: String?,
    effort: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    prompt: String,
    deadline: ContinuousClock.Instant
  ) async throws -> (taskID: String, status: String) {
    try Self.checkDeadline(deadline)
    let submission = MCPServiceTaskSubmission(
      projectID: projectID,
      prompt: prompt,
      providerID: providerID,
      installationID: installationID,
      executionModel: model,
      executionEffort: effort,
      modelOverride: model != nil || effort != nil ? true : nil,
      permissionMode: permissionMode,
      networkAccess: networkAccess,
      clientRequestID: "app-\(UUID().uuidString.lowercased())"
    )
    let receipt = try await serviceSubmitTask(
      submission,
      invocationContext: MCPInvocationContext(clientID: MCPClientID(rawValue: "macos.app")),
      deadline: deadline
    )
    return (receipt.taskID, receipt.status)
  }
}

public struct ServiceAgentModelListItem: Codable, Equatable, Sendable {
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
}

extension BridgeServiceApplication {
  /// Lists models advertised by the registered provider binary itself
  /// (config providers plus subscription catalogs such as Go/Zen).
  public func serviceListAgentModels(
    installationID: AgentInstallationID,
    projectID: String? = nil,
    modelID: String? = nil,
    useStoredDefault: Bool = true,
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentModelListItem] {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    let projectRoot = try await agentModelProjectRoot(
      projectID: projectID,
      deadline: deadline
    )
    try Self.checkDeadline(deadline)
    let selectedModelID: String?
    if let modelID {
      selectedModelID = modelID
    } else if useStoredDefault {
      guard let installation = try await registry.installation(id: installationID) else {
        throw BridgeMCPQueryError.unavailable
      }
      selectedModelID = try await serviceAgentModelDefault(
        providerID: installation.providerID,
        deadline: deadline
      ).model
    } else {
      selectedModelID = nil
    }
    let models = try await serviceAgentModelCatalog(
      registry: registry,
      installationID: installationID,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID
    )
    try Self.checkDeadline(deadline)
    return models.map {
      ServiceAgentModelListItem(
        modelID: $0.id,
        displayName: $0.displayName,
        supportedReasoningEfforts: $0.supportedReasoningEfforts,
        defaultReasoningEffort: $0.defaultReasoningEffort
      )
    }
  }

  func serviceAgentModelCatalog(
    registry: ServiceAgentRegistry,
    installationID: AgentInstallationID,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    guard try await registry.installation(id: installationID) != nil else {
      throw BridgeMCPQueryError.unavailable
    }
    return try await registry.models(
      installationID: installationID,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID
    )
  }

  private func agentModelProjectRoot(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    let selectedID: String?
    if let projectID {
      selectedID = projectID
    } else {
      selectedID = try await serviceWorkbenchProjectID(deadline: deadline)
    }
    guard let selectedID, !selectedID.isEmpty else { return nil }
    try Self.checkDeadline(deadline)
    return try await readableProject(selectedID).root.canonicalPath
  }
}

extension BridgeServiceApplication {
  public func serviceAgentModelDefault(
    providerID: AgentProviderID,
    deadline: ContinuousClock.Instant
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    try Self.checkDeadline(deadline)
    var model = try await settings.string(
      for: try Self.agentDefaultModelKey(providerID: providerID)
    )
    if providerID == .deepSeekHarness {
      model = try await migratedDeepSeekModelDefault(model)
    }
    let effort = try await settings.string(
      for: try Self.agentDefaultEffortKey(providerID: providerID)
    )
    let permissionMode =
      providerID == .openCode ? try await settings.openCodeDefaultPermissionMode() : "read-only"
    return (model, permissionMode, effort)
  }

  private func migratedDeepSeekModelDefault(_ model: String?) async throws -> String? {
    let prefix = "opencode-go/"
    guard let model, model.hasPrefix(prefix) else { return model }
    let wireModelID = String(model.dropFirst(prefix.count))
    let registry = try requiredAgentRegistry()
    guard
      let installation = try await registry.installations(providerID: .deepSeekHarness)
        .filter(\.isSelectable)
        .sorted(by: { $0.id.rawValue < $1.id.rawValue })
        .first,
      let catalog = try? await registry.models(
        installationID: installation.id,
        projectRoot: nil,
        selectedModelID: model
      ),
      !catalog.contains(where: { $0.id == model }),
      catalog.contains(where: { $0.id == wireModelID })
    else {
      return model
    }
    try await settings.set(wireModelID, for: .deepSeekHarnessDefaultModel)
    return wireModelID
  }

  public func serviceSetAgentModelDefault(
    providerID: AgentProviderID,
    model: String?,
    permissionMode: String?,
    effort: String?,
    updateEffort: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    try Self.checkDeadline(deadline)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.supportsModelSelection
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let validated = try Self.validatedAgentModel(model)
    try await settings.set(
      validated,
      for: try Self.agentDefaultModelKey(providerID: providerID)
    )
    if let permissionMode {
      guard providerID == .openCode else { throw BridgeMCPQueryError.contractRejected }
      try await settings.setOpenCodeDefaultPermissionMode(permissionMode)
    }
    if updateEffort {
      if let effort {
        guard !effort.isEmpty, effort.utf8.count <= 64,
          !effort.contains("\0"),
          effort.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw BridgeMCPQueryError.contractRejected }
      }
      try await settings.set(
        effort,
        for: try Self.agentDefaultEffortKey(providerID: providerID)
      )
    }
    return try await serviceAgentModelDefault(providerID: providerID, deadline: deadline)
  }

  public func serviceOpenCodeDefaultModel(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.string(for: .openCodeDefaultModel)
  }

  public func serviceSetOpenCodeDefaultModel(
    _ model: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let validated = try Self.validatedAgentModel(model)
    try await settings.set(validated, for: .openCodeDefaultModel)
  }

  public func serviceOpenCodeDefaultPermissionMode(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    try Self.checkDeadline(deadline)
    return try await settings.openCodeDefaultPermissionMode()
  }

  public func serviceSetOpenCodeDefaultPermissionMode(
    _ mode: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setOpenCodeDefaultPermissionMode(mode)
  }

  public func serviceOpenCodeDefaultEffort(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.openCodeDefaultEffort()
  }

  public func serviceSetOpenCodeDefaultEffort(
    _ effort: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setOpenCodeDefaultEffort(effort)
  }

  static func agentDefaultModelKey(providerID: AgentProviderID) throws
    -> ServiceSettingKey
  {
    if providerID == .openCode { return .openCodeDefaultModel }
    if providerID == .deepSeekHarness { return .deepSeekHarnessDefaultModel }
    throw BridgeMCPQueryError.contractRejected
  }

  static func agentDefaultEffortKey(providerID: AgentProviderID) throws
    -> ServiceSettingKey
  {
    if providerID == .openCode { return .openCodeDefaultEffort }
    if providerID == .deepSeekHarness { return .deepSeekHarnessDefaultEffort }
    throw BridgeMCPQueryError.contractRejected
  }
}
