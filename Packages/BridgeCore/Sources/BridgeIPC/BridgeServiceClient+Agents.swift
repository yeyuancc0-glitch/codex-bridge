extension BridgeServiceClient {
  public func agentCatalog() async throws -> IPCAgentCatalogResponse {
    try await call(
      operation: .getAgentCatalog,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func registerAgentInstallation(
    _ request: IPCAgentRegistrationRequest
  ) async throws -> IPCAgentInstallationSummary {
    try await call(operation: .registerAgentInstallation, payload: request)
  }

  public func reprobeAgentInstallation(
    installationID: String,
    acceptReplacement: Bool
  ) async throws -> IPCAgentInstallationSummary {
    try await call(
      operation: .reprobeAgentInstallation,
      payload: IPCAgentReprobeRequest(
        installationID: installationID,
        acceptReplacement: acceptReplacement
      )
    )
  }

  public func setAgentInstallationEnabled(
    installationID: String,
    enabled: Bool
  ) async throws -> IPCAgentInstallationSummary {
    try await call(
      operation: .setAgentInstallationEnabled,
      payload: IPCAgentEnabledRequest(installationID: installationID, enabled: enabled)
    )
  }

  public func removeAgentInstallation(installationID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .removeAgentInstallation,
      payload: IPCAgentInstallationIDRequest(installationID: installationID)
    )
  }

  public func submitAgentTask(
    _ request: IPCAgentSubmitRequest
  ) async throws -> IPCAgentSubmitResponse {
    try await call(operation: .submitAgentTask, payload: request)
  }

  public func agentModels(installationID: String) async throws -> IPCAgentModelsResponse {
    try await agentModels(
      installationID: installationID,
      projectID: nil,
      modelID: nil
    )
  }

  public func agentModels(
    installationID: String,
    projectID: String?
  ) async throws -> IPCAgentModelsResponse {
    try await agentModels(
      installationID: installationID,
      projectID: projectID,
      modelID: nil
    )
  }

  public func agentModels(
    installationID: String,
    projectID: String?,
    modelID: String?
  ) async throws -> IPCAgentModelsResponse {
    try await agentModels(
      installationID: installationID,
      projectID: projectID,
      modelID: modelID,
      useStoredDefault: true
    )
  }

  public func agentModels(
    installationID: String,
    projectID: String?,
    modelID: String?,
    useStoredDefault: Bool
  ) async throws -> IPCAgentModelsResponse {
    try await call(
      operation: .listAgentModels,
      payload: IPCAgentModelsRequest(
        installationID: installationID,
        projectID: projectID,
        modelID: modelID,
        useStoredDefault: useStoredDefault
      )
    )
  }

  public func agentModelDefault() async throws -> IPCAgentModelDefaultResponse {
    try await agentModelDefault(providerID: "opencode")
  }

  public func agentModelDefault(providerID: String) async throws -> IPCAgentModelDefaultResponse {
    try await call(
      operation: .getAgentModelDefault,
      payload: IPCAgentModelDefaultRequest(providerID: providerID, model: nil)
    )
  }

  public func setAgentModelDefault(_ model: String?) async throws {
    let _: IPCAgentModelDefaultResponse = try await call(
      operation: .setAgentModelDefault,
      payload: IPCAgentModelDefaultRequest(model: model)
    )
  }

  public func setOpenCodeDefaults(
    model: String?,
    permissionMode: String?,
    effort: String?
  ) async throws -> IPCAgentModelDefaultResponse {
    try await setAgentDefaults(
      providerID: "opencode",
      model: model,
      permissionMode: permissionMode,
      effort: effort
    )
  }

  public func setAgentDefaults(
    providerID: String,
    model: String?,
    permissionMode: String?,
    effort: String?
  ) async throws -> IPCAgentModelDefaultResponse {
    try await call(
      operation: .setAgentModelDefault,
      payload: IPCAgentModelDefaultRequest(
        providerID: providerID,
        model: model,
        permissionMode: permissionMode,
        effort: effort ?? ""
      )
    )
  }
}
