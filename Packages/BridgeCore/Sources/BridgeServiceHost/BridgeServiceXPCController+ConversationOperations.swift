import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleGetTaskConversation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationRequest.self,
      from: request
    )
    let records = try await composition.application.serviceConversationPage(
      taskID: payload.taskID,
      beforeMessageID: payload.beforeMessageID,
      limit: payload.limit,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCTaskConversationPage(
        taskID: payload.taskID,
        messages: records.map { message in
          IPCTaskConversationMessage(
            messageID: message.id,
            key: message.key,
            role: message.role.rawValue,
            kind: message.kind.rawValue,
            content: message.content,
            toolName: message.toolName,
            toolStatus: message.toolStatus,
            toolArguments: message.toolArguments
          )
        }
      )
    )
  }

  func handleSubscribeTaskConversation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    guard let streamProxy else {
      throw ServiceStoreError.invalidArgument("stream.unavailable")
    }
    await conversationStreamGate.acquire()
    defer { conversationStreamGate.release() }
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationRequest.self,
      from: request
    )
    let taskID = TaskID(rawValue: payload.taskID)
    if let previous = streams.take(taskID) {
      previous.forwarder.cancel()
      await composition.application.serviceUnsubscribeConversation(
        taskID: taskID,
        subscriptionID: previous.subscriptionID
      )
    }
    let subscription = try await composition.application.serviceSubscribeConversation(
      taskID: payload.taskID,
      limit: payload.limit,
      deadline: Self.deadline()
    )
    guard subscription.subscriptionID >= 0 else {
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID,
        payload: IPCTaskConversationSubscription(
          subscriptionID: -1,
          page: Self.conversationPage(taskID: payload.taskID, entries: subscription.page)
        )
      )
    }
    let forwarder = Task { [weak self, streamProxy] in
      for await change in subscription.updates {
        guard let push = Self.encodePush(change) else { continue }
        streamProxy.push(push)
      }
      await self?.removeForwarder(
        taskID: taskID,
        subscriptionID: subscription.subscriptionID
      )
    }
    let registration = StreamRegistration(
      forwarder: forwarder,
      subscriptionID: subscription.subscriptionID
    )
    if let replaced = streams.install(taskID: taskID, registration: registration) {
      await cancelRegistration(replaced, taskID: taskID)
    }
    do {
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID,
        payload: IPCTaskConversationSubscription(
          subscriptionID: subscription.subscriptionID,
          page: Self.conversationPage(taskID: payload.taskID, entries: subscription.page)
        )
      )
    } catch {
      if let failed = streams.take(taskID, subscriptionID: subscription.subscriptionID) {
        await cancelRegistration(failed, taskID: taskID)
      } else {
        await composition.application.serviceUnsubscribeConversation(
          taskID: taskID,
          subscriptionID: subscription.subscriptionID
        )
      }
      throw error
    }
  }

  func handleUnsubscribeTaskConversation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    await conversationStreamGate.acquire()
    defer { conversationStreamGate.release() }
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationUnsubscribeRequest.self,
      from: request
    )
    let taskID = TaskID(rawValue: payload.taskID)
    let registration = streams.take(taskID)
    registration?.forwarder.cancel()
    await composition.application.serviceUnsubscribeConversation(
      taskID: taskID,
      subscriptionID: registration?.subscriptionID ?? payload.subscriptionID
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleListApprovals(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload =
      try BridgeServiceIPCCodec.optionalPayload(
        IPCApprovalListRequest.self,
        from: request
      ) ?? IPCApprovalListRequest()
    let taskApprovals = try await composition.application.pendingTaskStartApprovals(
      taskID: payload.taskID.map(TaskID.init(rawValue:))
    )
    let approvals = await composition.application.pendingCodexApprovals(
      taskID: payload.taskID.map(TaskID.init(rawValue:))
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCApprovalListResponse(
        approvals: taskApprovals.map(Self.taskStartApprovalSummary)
          + approvals.map(Self.approvalSummary)
      )
    )
  }

  func handleResolveApproval(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCApprovalResolutionRequest.self,
      from: request
    )
    guard let decision = LocalApprovalDecision(rawValue: payload.decision) else {
      throw ServiceStoreError.invalidArgument("approval.decision")
    }
    let taskID = TaskID(rawValue: payload.taskID)
    if payload.approvalID.hasPrefix("bridge-task-start:") {
      guard decision == .allow || decision == .deny else {
        throw ServiceStoreError.invalidArgument("approval.decision")
      }
      try await composition.application.resolveTaskStartApproval(
        taskID: taskID,
        approvalID: payload.approvalID,
        approved: decision == .allow,
        deadline: Self.deadline()
      )
    } else {
      try await composition.application.resolveCodexApproval(
        taskID: taskID,
        approvalID: payload.approvalID,
        decision: decision
      )
    }
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleListDirectApprovals(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let pending = try await composition.application.servicePendingDirectApprovals(
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCDirectApprovalListResponse(
        approvals: pending.map {
          IPCPendingDirectApproval(
            approvalID: $0.approvalID,
            projectID: $0.projectID,
            kind: $0.kind.rawValue,
            summary: $0.summary,
            createdAt: $0.createdAt
          )
        }
      )
    )
  }

  func handleApproveDirectApproval(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCDirectApprovalDecisionRequest.self,
      from: request
    )
    let approved = try await composition.application.serviceApproveDirectApproval(
      approvalID: payload.approvalID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: approved
    )
  }

  func handleDenyDirectApproval(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCDirectApprovalDecisionRequest.self,
      from: request
    )
    let denied = try await composition.application.serviceDenyDirectApproval(
      approvalID: payload.approvalID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: denied
    )
  }

  func removeForwarder(taskID: TaskID, subscriptionID: Int) async {
    _ = streams.take(taskID, subscriptionID: subscriptionID)
  }

  private func cancelRegistration(
    _ registration: StreamRegistration,
    taskID: TaskID
  ) async {
    registration.forwarder.cancel()
    await composition.application.serviceUnsubscribeConversation(
      taskID: taskID,
      subscriptionID: registration.subscriptionID
    )
  }
}
