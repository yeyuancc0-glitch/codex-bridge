import BridgeIPC
import BridgeMCP
import Foundation

public protocol BridgeTaskConversationClient: Sendable {
  func taskConversation(_ request: IPCTaskConversationRequest) async throws
    -> IPCTaskConversationPage
  func subscribeTaskConversation(
    taskID: String,
    limit: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>)
  func unsubscribeTaskConversation(taskID: String, subscriptionID: Int) async throws
}

public protocol BridgeServiceClientProtocol: BridgeTaskConversationClient, Sendable {
  func status() async throws -> IPCServiceStatusResponse
  func projects() async throws -> [MCPProjectSummary]
  func registerProject(_ request: IPCProjectRegistrationRequest) async throws -> MCPProjectDetail
  func updateProjectPolicy(_ request: IPCProjectPolicyRequest) async throws -> MCPProjectDetail
  func projectCommands(projectID: String) async throws -> MCPProjectDetail
  func updateProjectCommands(
    projectID: String,
    commands: [IPCWorkspaceCommand],
    commandBlacklist: [IPCBlacklistRule]
  ) async throws -> MCPProjectDetail
  func setProjectCommandMode(projectID: String, commandMode: String) async throws
    -> MCPProjectDetail
  func setWorkbenchProject(projectID: String?) async throws
  func agentCatalog() async throws -> IPCAgentCatalogResponse
  func registerAgentInstallation(
    _ request: IPCAgentRegistrationRequest
  ) async throws -> IPCAgentInstallationSummary
  func reprobeAgentInstallation(
    installationID: String,
    acceptReplacement: Bool
  ) async throws -> IPCAgentInstallationSummary
  func setAgentInstallationEnabled(
    installationID: String,
    enabled: Bool
  ) async throws -> IPCAgentInstallationSummary
  func removeAgentInstallation(installationID: String) async throws
  func customInstructions() async throws -> String
  func setCustomInstructions(_ instructions: String) async throws
  func removeProject(projectID: String) async throws
  func models() async throws -> MCPModelList
  func modelCatalog() async throws -> IPCModelCatalogResponse
  func modelPreferences() async throws -> IPCModelPreferences
  func setModelPreferences(_ preferences: IPCModelPreferences) async throws
  func setSupervisorEnabled(_ enabled: Bool) async throws
  func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage
  func skills(projectID: String) async throws -> MCPServiceSkillList
  func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage
  func tasks(_ request: IPCTaskListRequest) async throws -> [MCPServiceTaskSnapshot]
  func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot
  func stopTask(taskID: String) async throws
  func deleteTask(taskID: String) async throws
  func approvals(taskID: String?) async throws -> [IPCApprovalSummary]
  func resolveApproval(_ request: IPCApprovalResolutionRequest) async throws
  func pendingDirectApprovals() async throws -> [IPCPendingDirectApproval]
  func approveDirectApproval(approvalID: String) async throws -> Bool
  func denyDirectApproval(approvalID: String) async throws -> Bool
  func directApprovalMode() async throws -> String
  func setDirectApprovalMode(_ mode: String) async throws
  func setExposureMode(_ mode: MCPServiceExposureMode) async throws
  func mcpClients() async throws -> [IPCMCPClientStatus]
  func setMCPClientEnabled(clientID: String, enabled: Bool) async throws
  func setMCPClientExposureMode(clientID: String, mode: MCPServiceExposureMode) async throws
  func exportMCPClientConfiguration(clientID: String) async throws -> String
  func rotateMCPClientCredential(clientID: String) async throws
  func rotateLocalMCPEndpoint() async throws -> String
  func configureTunnel(_ request: IPCTunnelConfigurationRequest) async throws -> IPCTunnelStatus
  func connectTunnel() async throws -> IPCTunnelStatus
  func disconnectTunnel() async throws
  func clearTunnel() async throws
  func close() async
}

extension BridgeServiceClient: BridgeServiceClientProtocol {
  public func close() async {
    invalidate()
  }
}

extension BridgeServiceClientProtocol {
  public func agentCatalog() async throws -> IPCAgentCatalogResponse {
    throw BridgeServiceClientError.unavailable
  }

  public func registerAgentInstallation(
    _ request: IPCAgentRegistrationRequest
  ) async throws -> IPCAgentInstallationSummary {
    throw BridgeServiceClientError.unavailable
  }

  public func reprobeAgentInstallation(
    installationID: String,
    acceptReplacement: Bool
  ) async throws -> IPCAgentInstallationSummary {
    throw BridgeServiceClientError.unavailable
  }

  public func setAgentInstallationEnabled(
    installationID: String,
    enabled: Bool
  ) async throws -> IPCAgentInstallationSummary {
    throw BridgeServiceClientError.unavailable
  }

  public func removeAgentInstallation(installationID: String) async throws {
    throw BridgeServiceClientError.unavailable
  }

  public func customInstructions() async throws -> String {
    throw BridgeServiceClientError.unavailable
  }

  public func setCustomInstructions(_ instructions: String) async throws {
    throw BridgeServiceClientError.unavailable
  }

  public func mcpClients() async throws -> [IPCMCPClientStatus] {
    throw BridgeServiceClientError.unavailable
  }

  public func setMCPClientEnabled(clientID: String, enabled: Bool) async throws {
    throw BridgeServiceClientError.unavailable
  }

  public func setMCPClientExposureMode(
    clientID: String,
    mode: MCPServiceExposureMode
  ) async throws {
    throw BridgeServiceClientError.unavailable
  }

  public func exportMCPClientConfiguration(clientID: String) async throws -> String {
    throw BridgeServiceClientError.unavailable
  }

  public func rotateMCPClientCredential(clientID: String) async throws {
    throw BridgeServiceClientError.unavailable
  }

  public func rotateLocalMCPEndpoint() async throws -> String {
    throw BridgeServiceClientError.unavailable
  }
}
