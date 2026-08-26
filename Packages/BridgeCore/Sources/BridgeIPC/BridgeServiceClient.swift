import BridgeMCP
import Foundation

public enum BridgeServiceClientError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case invalidRemoteProxy
  case responseFailed

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Codex Bridge Service is unavailable."
    case .invalidRemoteProxy:
      "Codex Bridge Service returned an invalid XPC proxy."
    case .responseFailed:
      "Codex Bridge Service did not return a valid response."
    }
  }
}

public actor BridgeServiceClient {
  private let connection: NSXPCConnection
  private let streamHub = CodexBridgeTaskStreamHub()
  private var invalidated = false

  public init(machServiceName: String = BridgeServiceIPC.machServiceName) {
    precondition(!machServiceName.isEmpty)
    let connection = NSXPCConnection(machServiceName: machServiceName)
    self.connection = connection
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.exportedInterface = NSXPCInterface(with: CodexBridgeTaskStreamListener.self)
    connection.exportedObject = CodexBridgeTaskStreamBridge(hub: streamHub)
    connection.resume()
  }

  public init(endpoint: NSXPCListenerEndpoint) {
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    self.connection = connection
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.exportedInterface = NSXPCInterface(with: CodexBridgeTaskStreamListener.self)
    connection.exportedObject = CodexBridgeTaskStreamBridge(hub: streamHub)
    connection.resume()
  }

  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    connection.invalidate()
    streamHub.clear()
  }

  public func status() async throws -> IPCServiceStatusResponse {
    try await call(operation: .status, payload: Optional<IPCMutationResponse>.none)
  }

  public func projects() async throws -> [MCPProjectSummary] {
    let response: IPCProjectListResponse = try await call(
      operation: .listProjects,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.projects
  }

  public func registerProject(
    _ request: IPCProjectRegistrationRequest
  ) async throws -> MCPProjectDetail {
    try await call(operation: .registerProject, payload: request)
  }

  public func updateProjectPolicy(
    _ request: IPCProjectPolicyRequest
  ) async throws -> MCPProjectDetail {
    try await call(operation: .updateProjectPolicy, payload: request)
  }

  public func removeProject(projectID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .removeProject,
      payload: IPCProjectIDRequest(projectID: projectID)
    )
  }

  public func projectCommands(projectID: String) async throws -> MCPProjectDetail {
    try await call(
      operation: .getProjectCommands,
      payload: IPCProjectCommandsRequest(projectID: projectID)
    )
  }

  public func updateProjectCommands(
    projectID: String,
    commands: [IPCWorkspaceCommand],
    commandBlacklist: [IPCBlacklistRule] = []
  ) async throws -> MCPProjectDetail {
    try await call(
      operation: .updateProjectCommands,
      payload: IPCProjectCommandsUpdateRequest(
        projectID: projectID,
        commands: commands,
        commandBlacklist: commandBlacklist
      )
    )
  }

  public func setProjectCommandMode(
    projectID: String,
    commandMode: String
  ) async throws -> MCPProjectDetail {
    try await call(
      operation: .setProjectCommandMode,
      payload: IPCProjectCommandModeUpdateRequest(projectID: projectID, commandMode: commandMode)
    )
  }

  public func setWorkbenchProject(projectID: String?) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setWorkbenchProject,
      payload: IPCWorkbenchProjectRequest(projectID: projectID)
    )
  }

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

  public func skills(projectID: String) async throws -> MCPServiceSkillList {
    try await call(
      operation: .listSkills,
      payload: IPCProjectSkillsRequest(projectID: projectID)
    )
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

  public func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage {
    try await call(operation: .listThreads, payload: request)
  }

  public func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage {
    try await call(operation: .readThread, payload: request)
  }

  public func tasks(_ request: IPCTaskListRequest = .init()) async throws
    -> [MCPServiceTaskSnapshot]
  {
    let response: IPCTaskListResponse = try await call(
      operation: .listTasks,
      payload: request
    )
    return response.tasks
  }

  public func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot {
    try await call(operation: .getTask, payload: request)
  }

  public func stopTask(taskID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .stopTask,
      payload: IPCTaskRequest(taskID: taskID)
    )
  }

  public func deleteTask(taskID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .deleteTask,
      payload: IPCTaskRequest(taskID: taskID)
    )
  }

  public func taskConversation(
    _ request: IPCTaskConversationRequest
  ) async throws -> IPCTaskConversationPage {
    try await call(operation: .getTaskConversation, payload: request)
  }

  public func subscribeTaskConversation(
    taskID: String,
    limit: Int = 200
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>) {
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    let updates = streamHub.register(taskID: taskID)
    do {
      let subscription: IPCTaskConversationSubscription = try await call(
        operation: .subscribeTaskConversation,
        payload: IPCTaskConversationRequest(taskID: taskID, limit: limit)
      )
      return (subscription, updates)
    } catch {
      streamHub.unregisterAll(taskID: taskID)
      throw error
    }
  }

  public func unsubscribeTaskConversation(
    taskID: String,
    subscriptionID: Int
  ) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .unsubscribeTaskConversation,
      payload: IPCTaskConversationUnsubscribeRequest(
        taskID: taskID,
        subscriptionID: subscriptionID
      )
    )
    streamHub.unregisterAll(taskID: taskID)
  }

  public func approvals(taskID: String? = nil) async throws -> [IPCApprovalSummary] {
    let response: IPCApprovalListResponse = try await call(
      operation: .listApprovals,
      payload: IPCApprovalListRequest(taskID: taskID)
    )
    return response.approvals
  }

  public func resolveApproval(
    _ request: IPCApprovalResolutionRequest
  ) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .resolveApproval,
      payload: request
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

  private func call<Payload: Encodable, Response: Decodable>(
    operation: BridgeServiceIPCOperation,
    payload: Payload?
  ) async throws -> Response {
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    let requestID = UUID().uuidString.lowercased()
    let data = try BridgeServiceIPCCodec.request(
      operation: operation,
      payload: payload,
      requestID: requestID
    )
    let response = try await perform(data)
    return try BridgeServiceIPCCodec.decodeResponse(
      Response.self,
      data: response,
      requestID: requestID
    )
  }

  private func perform(_ data: Data) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let completion = XPCClientCompletion(continuation)
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          completion.resume(throwing: BridgeServiceClientError.unavailable)
        }) as? CodexBridgeServiceXPCProtocol
      else {
        completion.resume(throwing: BridgeServiceClientError.invalidRemoteProxy)
        return
      }
      proxy.perform(data) { response in
        completion.resume(returning: response)
      }
    }
  }
}

private final class XPCClientCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, any Error>?

  init(_ continuation: CheckedContinuation<Data, any Error>) {
    self.continuation = continuation
  }

  func resume(returning data: Data) {
    resolve { $0.resume(returning: data) }
  }

  func resume(throwing error: any Error) {
    resolve { $0.resume(throwing: error) }
  }

  private func resolve(
    _ body: (CheckedContinuation<Data, any Error>) -> Void
  ) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    guard let continuation else { return }
    body(continuation)
  }
}

extension BridgeServiceClient {
  public func submitAgentTask(
    _ request: IPCAgentSubmitRequest
  ) async throws -> IPCAgentSubmitResponse {
    try await call(operation: .submitAgentTask, payload: request)
  }

  public func agentModels(installationID: String) async throws -> IPCAgentModelsResponse {
    try await call(
      operation: .listAgentModels,
      payload: IPCAgentModelsRequest(installationID: installationID)
    )
  }
}

extension BridgeServiceClient {
  public func agentModelDefault() async throws -> IPCAgentModelDefaultResponse {
    try await call(
      operation: .getAgentModelDefault,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func setAgentModelDefault(_ model: String?) async throws {
    let _: IPCAgentModelDefaultResponse = try await call(
      operation: .setAgentModelDefault,
      payload: IPCAgentModelDefaultRequest(model: model)
    )
  }
}
