import BridgeMCP

extension BridgeServiceClient {
  public func skills(projectID: String) async throws -> MCPServiceSkillList {
    try await call(
      operation: .listSkills,
      payload: IPCProjectSkillsRequest(projectID: projectID)
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

  public func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String
  ) async throws -> MCPServiceTaskMutationReceipt {
    try await call(
      operation: .steerTask,
      payload: IPCTaskSteerRequest(
        taskID: taskID,
        expectedTurnID: expectedTurnID,
        input: input
      )
    )
  }

  public func interruptTask(
    taskID: String,
    expectedTurnID: String
  ) async throws -> MCPServiceTaskMutationReceipt {
    try await call(
      operation: .interruptTask,
      payload: IPCTaskInterruptRequest(
        taskID: taskID,
        expectedTurnID: expectedTurnID
      )
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
}
