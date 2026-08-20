import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleGetTaskConversation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationRequest.self,
      from: request
    )
    guard (1...500).contains(payload.limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    let records = try await composition.coordinator.conversationPage(
      taskID: TaskID(rawValue: payload.taskID),
      beforeMessageID: payload.beforeMessageID,
      limit: payload.limit
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
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationRequest.self,
      from: request
    )
    guard (1...500).contains(payload.limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    let taskID = TaskID(rawValue: payload.taskID)
    let previousForwarder = streams.takeForwarder(taskID)
    let previousSubscription = streams.takeSubscription(taskID)
    previousForwarder?.cancel()
    if let previousSubscription {
      await composition.coordinator.unsubscribeConversation(
        taskID: taskID,
        subscriptionID: previousSubscription
      )
    }
    let subscription = try await composition.coordinator.subscribeConversation(
      taskID: taskID,
      limit: payload.limit
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
      await self?.removeForwarder(taskID: taskID)
    }
    streams.put(
      taskID: taskID, forwarder: forwarder, subscriptionID: subscription.subscriptionID)
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCTaskConversationSubscription(
        subscriptionID: subscription.subscriptionID,
        page: Self.conversationPage(taskID: payload.taskID, entries: subscription.page)
      )
    )
  }

  func handleUnsubscribeTaskConversation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTaskConversationUnsubscribeRequest.self,
      from: request
    )
    let taskID = TaskID(rawValue: payload.taskID)
    let forwarder = streams.takeForwarder(taskID)
    let subscriptionID = streams.takeSubscription(taskID)
    forwarder?.cancel()
    await composition.coordinator.unsubscribeConversation(
      taskID: taskID,
      subscriptionID: subscriptionID ?? payload.subscriptionID
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleListApprovals(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload =
      try BridgeServiceIPCCodec.optionalPayload(
        IPCApprovalListRequest.self,
        from: request
      ) ?? IPCApprovalListRequest()
    let approvals = await composition.application.pendingCodexApprovals(
      taskID: payload.taskID.map(TaskID.init(rawValue:))
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCApprovalListResponse(
        approvals: approvals.map(Self.approvalSummary)
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
    try await composition.application.resolveCodexApproval(
      taskID: TaskID(rawValue: payload.taskID),
      approvalID: payload.approvalID,
      decision: decision
    )
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

  func removeForwarder(taskID: TaskID) async {
    streams.removeForwarder(taskID)
  }
}
