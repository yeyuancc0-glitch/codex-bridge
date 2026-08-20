import BridgeIPC
import Foundation

public final class BridgeServiceXPCController: NSObject, CodexBridgeServiceXPCProtocol,
  @unchecked Sendable
{
  let composition: ServiceComposition
  let admission: XPCRequestAdmission
  let streamProxy: CodexBridgeTaskStreamListener?
  let streams = StreamRegistry()

  public init(
    composition: ServiceComposition,
    streamProxy: CodexBridgeTaskStreamListener? = nil,
    maximumConcurrentRequests: Int = 8
  ) {
    precondition(maximumConcurrentRequests > 0)
    self.composition = composition
    self.streamProxy = streamProxy
    self.admission = XPCRequestAdmission(
      maximumConcurrent: maximumConcurrentRequests
    )
    super.init()
  }

  public func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = XPCReplyBox(reply)
    let decoded: BridgeServiceIPCRequest
    do {
      decoded = try BridgeServiceIPCCodec.decodeRequest(request)
    } catch {
      replyBox.call(
        Self.fallbackFailure(
          requestID: "invalid",
          code: "invalid_request",
          message: "The XPC request is invalid."
        )
      )
      return
    }
    guard admission.acquire() else {
      replyBox.call(
        Self.fallbackFailure(
          requestID: decoded.requestID,
          code: "busy",
          message: "The service is busy.",
          retryable: true
        )
      )
      return
    }
    Task { [weak self] in
      let response =
        await self?.handle(decoded)
        ?? Self.fallbackFailure(
          requestID: decoded.requestID,
          code: "unavailable",
          message: "The service is unavailable.",
          retryable: true
        )
      self?.admission.release()
      replyBox.call(response)
    }
  }

  public func stopStreaming() {
    let (activeForwarders, activeSubscriptions) = streams.takeAll()
    for task in activeForwarders.values {
      task.cancel()
    }
    for (taskID, subscriptionID) in activeSubscriptions {
      Task {
        await composition.coordinator.unsubscribeConversation(
          taskID: taskID,
          subscriptionID: subscriptionID
        )
      }
    }
  }

  private func handle(_ request: BridgeServiceIPCRequest) async -> Data {
    do {
      return try await handleOperation(request)
    } catch {
      let mapped = Self.map(error)
      return Self.fallbackFailure(
        requestID: request.requestID,
        code: mapped.code,
        message: mapped.message,
        retryable: mapped.retryable
      )
    }
  }

  private func handleOperation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    switch request.operation {
    case .status:
      return try await handleStatus(request)
    case .listProjects:
      return try await handleListProjects(request)
    case .registerProject:
      return try await handleRegisterProject(request)
    case .updateProjectPolicy:
      return try await handleUpdateProjectPolicy(request)
    case .removeProject:
      return try await handleRemoveProject(request)
    case .getProjectCommands:
      return try await handleGetProjectCommands(request)
    case .updateProjectCommands:
      return try await handleUpdateProjectCommands(request)
    case .setProjectCommandMode:
      return try await handleSetProjectCommandMode(request)
    case .listModels:
      return try await handleListModels(request)
    case .getModelCatalog:
      return try await handleGetModelCatalog(request)
    case .getModelPreferences:
      return try await handleGetModelPreferences(request)
    case .setModelPreferences:
      return try await handleSetModelPreferences(request)
    case .setSupervisorEnabled:
      return try await handleSetSupervisorEnabled(request)
    case .listThreads:
      return try await handleListThreads(request)
    case .listSkills:
      return try await handleListSkills(request)
    case .readThread:
      return try await handleReadThread(request)
    case .listTasks:
      return try await handleListTasks(request)
    case .getTask:
      return try await handleGetTask(request)
    case .stopTask:
      return try await handleStopTask(request)
    case .deleteTask:
      return try await handleDeleteTask(request)
    case .getTaskConversation:
      return try await handleGetTaskConversation(request)
    case .subscribeTaskConversation:
      return try await handleSubscribeTaskConversation(request)
    case .unsubscribeTaskConversation:
      return try await handleUnsubscribeTaskConversation(request)
    case .listApprovals:
      return try await handleListApprovals(request)
    case .resolveApproval:
      return try await handleResolveApproval(request)
    case .listDirectApprovals:
      return try await handleListDirectApprovals(request)
    case .approveDirectApproval:
      return try await handleApproveDirectApproval(request)
    case .denyDirectApproval:
      return try await handleDenyDirectApproval(request)
    case .getDirectApprovalMode:
      return try await handleGetDirectApprovalMode(request)
    case .setDirectApprovalMode:
      return try await handleSetDirectApprovalMode(request)
    case .setExposureMode:
      return try await handleSetExposureMode(request)
    case .configureTunnel:
      return try await handleConfigureTunnel(request)
    case .connectTunnel:
      return try await handleConnectTunnel(request)
    case .disconnectTunnel:
      return try await handleDisconnectTunnel(request)
    case .clearTunnel:
      return try await handleClearTunnel(request)
    }
  }
}
