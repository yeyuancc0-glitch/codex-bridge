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
    } else {
      selectedModelID = try await settings.string(for: .openCodeDefaultModel)
    }
    let models = try await registry.models(
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
}
