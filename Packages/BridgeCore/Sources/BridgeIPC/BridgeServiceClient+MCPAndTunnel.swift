import BridgeMCP

extension BridgeServiceClient {
  public func status() async throws -> IPCServiceStatusResponse {
    try await call(operation: .status, payload: Optional<IPCMutationResponse>.none)
  }

  public func customInstructions() async throws -> String {
    let response: IPCCustomInstructions = try await call(
      operation: .getCustomInstructions,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.instructions
  }

  public func setCustomInstructions(_ instructions: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setCustomInstructions,
      payload: IPCCustomInstructions(instructions: instructions)
    )
  }

  public func models() async throws -> MCPModelList {
    try await call(operation: .listModels, payload: Optional<IPCMutationResponse>.none)
  }

  public func modelCatalog() async throws -> IPCModelCatalogResponse {
    do {
      return try await call(
        operation: .getModelCatalog,
        payload: Optional<IPCMutationResponse>.none
      )
    } catch let error as BridgeServiceIPCCodecError {
      let shouldFallback: Bool
      switch error {
      case .requestMismatch:
        shouldFallback = true
      case .remoteError(let remote):
        shouldFallback = remote.code == "invalid_request"
      default:
        shouldFallback = false
      }
      guard shouldFallback else { throw error }
      let models = try await models()
      let preferences = try await modelPreferences()
      return IPCModelCatalogResponse(models: models.models, preferences: preferences)
    }
  }

  public func modelPreferences() async throws -> IPCModelPreferences {
    try await call(
      operation: .getModelPreferences,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func setModelPreferences(_ preferences: IPCModelPreferences) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setModelPreferences,
      payload: preferences
    )
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setSupervisorEnabled,
      payload: IPCSupervisorEnabledRequest(enabled: enabled)
    )
  }

  public func directApprovalMode() async throws -> String {
    let response: IPCDirectApprovalModeResponse = try await call(
      operation: .getDirectApprovalMode,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.mode
  }

  public func setDirectApprovalMode(_ mode: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setDirectApprovalMode,
      payload: IPCDirectApprovalModeRequest(mode: mode)
    )
  }

  public func taskStartApprovalMode() async throws -> String {
    let response: IPCTaskStartApprovalModeResponse = try await call(
      operation: .getTaskStartApprovalMode,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.mode
  }

  public func setTaskStartApprovalMode(_ mode: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setTaskStartApprovalMode,
      payload: IPCTaskStartApprovalModeRequest(mode: mode)
    )
  }

  public func pendingDirectApprovals() async throws -> [IPCPendingDirectApproval] {
    let response: IPCDirectApprovalListResponse = try await call(
      operation: .listDirectApprovals,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.approvals
  }

  public func approveDirectApproval(approvalID: String) async throws -> Bool {
    try await call(
      operation: .approveDirectApproval,
      payload: IPCDirectApprovalDecisionRequest(approvalID: approvalID)
    )
  }

  public func denyDirectApproval(approvalID: String) async throws -> Bool {
    try await call(
      operation: .denyDirectApproval,
      payload: IPCDirectApprovalDecisionRequest(approvalID: approvalID)
    )
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setExposureMode,
      payload: IPCExposureModeRequest(exposureMode: mode)
    )
  }

  public func mcpClients() async throws -> [IPCMCPClientStatus] {
    let response: IPCMCPClientListResponse = try await call(
      operation: .listMCPClients,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.clients
  }

  public func setMCPClientEnabled(clientID: String, enabled: Bool) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setMCPClientEnabled,
      payload: IPCMCPClientEnabledRequest(clientID: clientID, enabled: enabled)
    )
  }

  public func setMCPClientExposureMode(
    clientID: String,
    mode: MCPServiceExposureMode
  ) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setMCPClientExposureMode,
      payload: IPCMCPClientExposureRequest(clientID: clientID, exposureMode: mode)
    )
  }

  public func exportMCPClientConfiguration(clientID: String) async throws -> String {
    let response: IPCMCPClientConfigurationExport = try await call(
      operation: .exportMCPClientConfiguration,
      payload: IPCMCPClientRequest(clientID: clientID)
    )
    return response.configurationJSON
  }

  public func rotateMCPClientCredential(clientID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .rotateMCPClientCredential,
      payload: IPCMCPClientRequest(clientID: clientID)
    )
  }

  public func rotateLocalMCPEndpoint() async throws -> String {
    let response: IPCLocalMCPEndpointResponse = try await call(
      operation: .rotateLocalMCPEndpoint,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.localMCPURL
  }

  public func configureTunnel(
    _ request: IPCTunnelConfigurationRequest
  ) async throws -> IPCTunnelStatus {
    try await call(operation: .configureTunnel, payload: request)
  }

  public func connectTunnel() async throws -> IPCTunnelStatus {
    try await call(
      operation: .connectTunnel,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func disconnectTunnel() async throws {
    let _: IPCMutationResponse = try await call(
      operation: .disconnectTunnel,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func clearTunnel() async throws {
    let _: IPCMutationResponse = try await call(
      operation: .clearTunnel,
      payload: Optional<IPCMutationResponse>.none
    )
  }
}
