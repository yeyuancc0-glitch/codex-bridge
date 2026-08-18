import BridgeIPC
import BridgeMCP
import Foundation

public protocol BridgeServiceClientProtocol: Sendable {
  func status() async throws -> IPCServiceStatusResponse
  func projects() async throws -> [MCPProjectSummary]
  func registerProject(_ request: IPCProjectRegistrationRequest) async throws -> MCPProjectDetail
  func updateProjectPolicy(_ request: IPCProjectPolicyRequest) async throws -> MCPProjectDetail
  func projectCommands(projectID: String) async throws -> MCPProjectDetail
  func updateProjectCommands(
    projectID: String,
    commands: [IPCWorkspaceCommand]
  ) async throws -> MCPProjectDetail
  func setProjectCommandMode(projectID: String, commandMode: String) async throws
    -> MCPProjectDetail
  func removeProject(projectID: String) async throws
  func models() async throws -> MCPModelList
  func modelCatalog() async throws -> IPCModelCatalogResponse
  func modelPreferences() async throws -> IPCModelPreferences
  func setModelPreferences(_ preferences: IPCModelPreferences) async throws
  func setSupervisorEnabled(_ enabled: Bool) async throws
  func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage
  func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage
  func tasks(_ request: IPCTaskListRequest) async throws -> [MCPServiceTaskSnapshot]
  func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot
  func stopTask(taskID: String) async throws
  func deleteTask(taskID: String) async throws
  func taskConversation(_ request: IPCTaskConversationRequest) async throws
    -> IPCTaskConversationPage
  func subscribeTaskConversation(
    taskID: String,
    limit: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>)
  func unsubscribeTaskConversation(taskID: String, subscriptionID: Int) async throws
  func approvals(taskID: String?) async throws -> [IPCApprovalSummary]
  func resolveApproval(_ request: IPCApprovalResolutionRequest) async throws
  func setExposureMode(_ mode: MCPServiceExposureMode) async throws
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
