import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  /// Explicit non-Codex submissions resolve against the user-registered agent
  /// installations. Provider-specific task constraints live in the shared
  /// service policy registry; adapter capabilities are checked by the runner.
  func prepareAgentSubmission(
    _ submission: MCPServiceTaskSubmission,
    providerRaw: String,
    project: ServiceProjectRecord,
    sourceClientID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let providerID = AgentProviderID(rawValue: providerRaw)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.requiresInstallation
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard
      policy.supportsSupervisor
        || (submission.supervisorModel == nil && submission.supervisorEffort == nil)
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard policy.supportsSkillSelection || submission.skillName == nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard policy.supportsSessionContinuation || submission.threadID == nil else {
      throw BridgeMCPQueryError.contractRejected
    }

    let usesOverride = submission.modelOverride == true
    let requestedModel = usesOverride ? submission.executionModel : nil
    let requestedEffort = usesOverride ? submission.executionEffort : nil
    if !policy.supportsModelSelection && requestedModel != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if !policy.supportsEffortSelection && requestedEffort != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if let model = requestedModel {
      guard !model.isEmpty, model.utf8.count <= 256,
        model.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw BridgeMCPQueryError.contractRejected }
    }
    // A remote MCP model can fill optional tool arguments from its own safety
    // preference. Only a submission explicitly marked as a user-requested
    // override may replace persisted provider defaults. The nil case keeps
    // older in-process callers source-compatible; the MCP parser normalizes a
    // missing marker to false.
    let configuredModel: String?
    let configuredEffort: String?
    let defaultMode: ServicePermissionMode
    if policy.providerID == .openCode {
      configuredModel = try await settings.string(for: .openCodeDefaultModel)
      configuredEffort = try await settings.openCodeDefaultEffort()
      let configuredMode = try await settings.openCodeDefaultPermissionMode()
      defaultMode = configuredMode == "plan" ? .readOnly : .workspaceWrite
    } else if policy.providerID == .deepSeekHarness {
      configuredModel = try await settings.string(for: .deepSeekHarnessDefaultModel)
      configuredEffort = try await settings.string(for: .deepSeekHarnessDefaultEffort)
      let configuredMode = try await settings.deepSeekHarnessDefaultPermissionMode()
      defaultMode = configuredMode == "read-only" ? .readOnly : .workspaceWrite
    } else if policy.providerID == .antigravity {
      configuredModel = try await settings.antigravityDefaultModel()
      configuredEffort = try await settings.antigravityDefaultEffort()
      let configuredMode = try await settings.antigravityDefaultPermissionMode()
      defaultMode = configuredMode == "read-only" ? .readOnly : .workspaceWrite
    } else {
      configuredModel = nil
      configuredEffort = nil
      defaultMode = policy.defaultPermissionMode
    }
    if !policy.supportsWorkspaceWrite,
      submission.permissionMode == ServicePermissionMode.workspaceWrite.rawValue
    {
      throw BridgeMCPQueryError.contractRejected
    }
    let requestedPermissionMode =
      submission.permissionModeOverride == false ? nil : submission.permissionMode
    let permission = try Self.permissionMode(
      requestedPermissionMode,
      project: project,
      defaultMode: defaultMode
    )
    guard policy.supportsWorkspaceWrite || permission != .workspaceWrite else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard !submission.networkAccess || policy.allowsNetworkAccess else {
      // Provider policies never persist a requested network grant as though
      // the Bridge enforced it when the adapter has no task-level sandbox.
      throw BridgeMCPQueryError.unavailable
    }
    let registry = try requiredAgentRegistry()
    let selectable =
      try await registry.installations(providerID: providerID)
      .filter { $0.isSelectable }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    let record = try Self.selectAgentInstallation(
      requested: submission.installationID, from: selectable)
    let effectiveCapabilities = policy.effectiveCapabilities(
      record.capabilities.effective,
      projectAllowsWorkspaceWrite: project.accessPolicy.write != .denied
    )
    let supportsModelSelection = effectiveCapabilities.contains(.modelSelection)
    if requestedModel != nil, !supportsModelSelection {
      throw BridgeMCPQueryError.unavailable
    }
    if policy.selectionsRequireObservedCapabilities {
      var requiredCapabilities = Set<AgentCapability>()
      if submission.threadID != nil { requiredCapabilities.insert(.sessionContinue) }
      if requestedModel != nil { requiredCapabilities.insert(.modelSelection) }
      if requestedEffort != nil { requiredCapabilities.insert(.effortSelection) }
      guard effectiveCapabilities.isSuperset(of: requiredCapabilities) else {
        throw BridgeMCPQueryError.unavailable
      }
    }
    let resolvedModel = try Self.validatedAgentModel(
      supportsModelSelection ? (requestedModel ?? configuredModel) : nil
    )
    if policy.supportsSessionContinuation, let requestedSessionID = submission.threadID {
      guard
        let previous = try await tasks.task(
          providerSessionID: requestedSessionID,
          providerID: providerID.rawValue,
          installationID: record.id.rawValue,
          projectID: project.id
        )
      else {
        throw BridgeMCPQueryError.taskNotFound
      }
      guard previous.state.status.isTerminal else {
        throw BridgeMCPQueryError.invalidTaskState
      }
    }
    let modelCatalog: [AgentModelDescriptor]?
    if supportsModelSelection {
      modelCatalog = try? await serviceAgentModelCatalog(
        registry: registry,
        installationID: record.id,
        projectRoot: project.root.canonicalPath,
        selectedModelID: resolvedModel
      )
    } else {
      modelCatalog = nil
    }
    let selectedDescriptor: AgentModelDescriptor?
    if let modelCatalog {
      if let resolvedModel {
        selectedDescriptor =
          modelCatalog.first(where: { $0.id == resolvedModel })
          ?? Self.legacyDeepSeekDescriptor(
            providerID: policy.providerID,
            modelID: resolvedModel,
            catalog: modelCatalog
          )
      } else {
        selectedDescriptor = modelCatalog.first(where: {
          !$0.supportedReasoningEfforts.isEmpty
        })
      }
    } else {
      selectedDescriptor = nil
    }
    if policy.providerID == .deepSeekHarness, resolvedModel != nil, selectedDescriptor == nil {
      throw BridgeMCPQueryError.unavailable
    }
    let executionEffort: String
    if let requestedEffort {
      guard modelCatalog != nil else { throw BridgeMCPQueryError.unavailable }
      guard selectedDescriptor?.supportedReasoningEfforts.contains(requestedEffort) == true else {
        throw BridgeMCPQueryError.contractRejected
      }
      executionEffort = requestedEffort
    } else if let configuredEffort,
      selectedDescriptor?.supportedReasoningEfforts.contains(configuredEffort) == true
    {
      executionEffort = configuredEffort
    } else {
      executionEffort = serviceDefaultProviderExecutionEffort
    }
    let prompt = try await taskPrompt(
      for: submission,
      project: project,
      deadline: deadline
    )
    let accessMode = try await settings.accessMode()
    let executionModel =
      supportsModelSelection
      ? selectedDescriptor?.id ?? resolvedModel ?? serviceDefaultProviderExecutionModel
      : serviceDefaultProviderExecutionModel
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: sourceClientID,
        clientRequestID: submission.clientRequestID,
        prompt: prompt,
        requestedThreadID: submission.threadID,
        providerID: providerID.rawValue,
        installationID: record.id.rawValue,
        selectionMode: .explicit,
        executionModel: executionModel,
        executionEffort: executionEffort,
        permissionMode: permission,
        networkAllowed: submission.networkAccess,
        accessMode: accessMode
      )
    )
  }

  private static func legacyDeepSeekDescriptor(
    providerID: AgentProviderID,
    modelID: String,
    catalog: [AgentModelDescriptor]
  ) -> AgentModelDescriptor? {
    let prefix = "opencode-go/"
    guard providerID == .deepSeekHarness, modelID.hasPrefix(prefix) else { return nil }
    let wireModelID = String(modelID.dropFirst(prefix.count))
    return catalog.first(where: { $0.id == wireModelID })
  }

  static func validatedAgentModel(_ model: String?) throws -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return trimmed
  }

  static func selectAgentInstallation(
    requested: String?,
    from selectable: [ServiceAgentInstallationRecord]
  ) throws -> ServiceAgentInstallationRecord {
    if let requested {
      guard let record = selectable.first(where: { $0.id.rawValue == requested }) else {
        throw BridgeMCPQueryError.unavailable
      }
      return record
    }
    guard let record = selectable.first else {
      throw BridgeMCPQueryError.unavailable
    }
    return record
  }
}
