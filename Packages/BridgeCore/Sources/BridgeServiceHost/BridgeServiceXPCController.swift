import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import BridgeTunnel
import Foundation

public final class BridgeServiceXPCController: NSObject, CodexBridgeServiceXPCProtocol,
  @unchecked Sendable
{
  private let composition: ServiceComposition
  private let admission: XPCRequestAdmission
  private let streamProxy: CodexBridgeTaskStreamListener?
  private let streams = StreamRegistry()

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
      switch request.operation {
      case .status:
        let status = try await composition.application.serviceStatus(
          deadline: Self.deadline()
        )
        let endpoint = await composition.endpoint()?.localURL.absoluteString
        let exposureMode = try await composition.settings.exposureMode()
        let tunnel = await composition.tunnelStatus()
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCServiceStatusResponse(
            status: status,
            localMCPURL: endpoint,
            exposureMode: Self.mcpExposureMode(exposureMode),
            tunnel: Self.tunnelStatus(tunnel)
          )
        )

      case .listProjects:
        let page = try await composition.application.serviceProjects(
          cursor: nil,
          limit: 100,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCProjectListResponse(projects: page.projects)
        )

      case .registerProject:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectRegistrationRequest.self,
          from: request
        )
        let policy = try Self.projectPolicy(
          read: payload.readPermission,
          write: payload.writePermission,
          network: payload.networkPermission
        )
        let project = try await composition.projects.register(
          name: payload.name,
          rootURL: try Self.absoluteDirectoryURL(payload.absolutePath),
          accessPolicy: policy
        )
        let detail = try await composition.application.serviceProject(
          projectID: project.id.rawValue,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: detail
        )

      case .updateProjectPolicy:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectPolicyRequest.self,
          from: request
        )
        _ = try await composition.projects.updateAccessPolicy(
          try Self.projectPolicy(
            read: payload.readPermission,
            write: payload.writePermission,
            network: payload.networkPermission
          ),
          projectID: ProjectID(rawValue: payload.projectID)
        )
        let detail = try await composition.application.serviceProject(
          projectID: payload.projectID,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: detail
        )

      case .getProjectCommands:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectCommandsRequest.self,
          from: request
        )
        let detail = try await composition.application.serviceProject(
          projectID: payload.projectID,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: detail
        )

      case .updateProjectCommands:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectCommandsUpdateRequest.self,
          from: request
        )
        _ = try await composition.projects.updateWorkspaceConfiguration(
          directCommandMode: .registered,
          workspaceCommands: try Self.workspaceCommands(payload.commands),
          projectID: ProjectID(rawValue: payload.projectID)
        )
        let updatedCommands = try await composition.application.serviceProject(
          projectID: payload.projectID,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: updatedCommands
        )

      case .setProjectCommandMode:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectCommandModeUpdateRequest.self,
          from: request
        )
        guard let mode = ServiceDirectCommandMode(rawValue: payload.commandMode) else {
          throw ServiceStoreError.invalidArgument("project.commandMode")
        }
        let current = try await composition.projects.project(
          id: ProjectID(rawValue: payload.projectID)
        )
        guard let current else {
          throw ServiceStoreError.unknownProject(ProjectID(rawValue: payload.projectID))
        }
        _ = try await composition.projects.updateWorkspaceConfiguration(
          directCommandMode: mode,
          workspaceCommands: current.workspaceCommands,
          projectID: ProjectID(rawValue: payload.projectID)
        )
        let updatedMode = try await composition.application.serviceProject(
          projectID: payload.projectID,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: updatedMode
        )

      case .removeProject:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCProjectIDRequest.self,
          from: request
        )
        let taskList = try await composition.tasks.tasks(
          projectID: ProjectID(rawValue: payload.projectID),
          limit: 500
        )
        guard taskList.allSatisfy({ $0.state.status.isTerminal }) else {
          throw ServiceStoreError.invalidArgument("project.activeTasks")
        }
        try await composition.projects.remove(
          projectID: ProjectID(rawValue: payload.projectID)
        )
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .listModels:
        let models = try await composition.application.serviceModels(deadline: Self.deadline())
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: models
        )

      case .getModelCatalog:
        let catalog = try await composition.application.serviceModelCatalog(
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCModelCatalogResponse(
            models: catalog.models.models,
            preferences: IPCModelPreferences(
              executionModel: catalog.preferences.executionModel,
              executionEffort: catalog.preferences.executionEffort,
              supervisorModel: catalog.preferences.supervisorModel,
              supervisorEffort: catalog.preferences.supervisorEffort,
              supervisorEnabled: try await composition.settings.isSupervisorEnabled(),
              accessMode: catalog.preferences.accessMode.rawValue,
              fastModeEnabled: catalog.preferences.fastModeEnabled
            )
          )
        )

      case .getModelPreferences:
        let preferences = try await composition.application.serviceModelPreferences(
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCModelPreferences(
            executionModel: preferences.executionModel,
            executionEffort: preferences.executionEffort,
            supervisorModel: preferences.supervisorModel,
            supervisorEffort: preferences.supervisorEffort,
            supervisorEnabled: try await composition.settings.isSupervisorEnabled(),
            accessMode: preferences.accessMode.rawValue,
            fastModeEnabled: preferences.fastModeEnabled
          )
        )

      case .setModelPreferences:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCModelPreferences.self,
          from: request
        )
        guard let accessMode = ServiceAccessMode(rawValue: payload.accessMode) else {
          throw ServiceStoreError.invalidArgument("preferences.accessMode")
        }
        try await composition.application.setServiceModelPreferences(
          ServiceModelPreferences(
            executionModel: payload.executionModel,
            executionEffort: payload.executionEffort,
            supervisorModel: payload.supervisorModel,
            supervisorEffort: payload.supervisorEffort,
            accessMode: accessMode,
            fastModeEnabled: payload.fastModeEnabled
          ),
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .setSupervisorEnabled:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCSupervisorEnabledRequest.self,
          from: request
        )
        try await composition.application.setSupervisorEnabled(payload.enabled)
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .listThreads:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCThreadListRequest.self,
          from: request
        )
        let page = try await composition.application.serviceThreads(
          projectID: payload.projectID,
          cursor: payload.cursor,
          limit: payload.limit,
          search: payload.search,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: page
        )

      case .readThread:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCThreadReadRequest.self,
          from: request
        )
        let page = try await composition.application.serviceReadThread(
          projectID: payload.projectID,
          threadID: payload.threadID,
          detail: payload.detail,
          cursor: payload.cursor,
          limit: payload.limit,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: page
        )

      case .listTasks:
        let payload =
          try BridgeServiceIPCCodec.optionalPayload(
            IPCTaskListRequest.self,
            from: request
          ) ?? IPCTaskListRequest()
        guard (1...500).contains(payload.limit) else {
          throw ServiceStoreError.invalidArgument("tasks.limit")
        }
        let projectID = payload.projectID.map(ProjectID.init(rawValue:))
        let taskList = try await composition.tasks.tasks(
          projectID: projectID,
          limit: payload.limit
        )
        var snapshots: [MCPServiceTaskSnapshot] = []
        snapshots.reserveCapacity(taskList.count)
        for task in taskList {
          snapshots.append(
            try await composition.application.serviceTask(
              taskID: task.id.rawValue,
              recentEventLimit: 10,
              deadline: Self.deadline()
            )
          )
        }
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCTaskListResponse(tasks: snapshots)
        )

      case .getTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        let task = try await composition.application.serviceTask(
          taskID: payload.taskID,
          recentEventLimit: payload.recentEventLimit,
          deadline: Self.deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: task
        )

      case .stopTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        await composition.coordinator.stop(taskID: TaskID(rawValue: payload.taskID))
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .deleteTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        let taskID = TaskID(rawValue: payload.taskID)
        try await composition.tasks.remove(taskID: taskID)
        await composition.coordinator.purgeConversation(taskID: taskID)
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .getTaskConversation:
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

      case .subscribeTaskConversation:
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

      case .unsubscribeTaskConversation:
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

      case .listApprovals:
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

      case .resolveApproval:
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

      case .listDirectApprovals:
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

      case .approveDirectApproval:
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

      case .denyDirectApproval:
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

      case .setExposureMode:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCExposureModeRequest.self,
          from: request
        )
        _ = try await composition.setExposureMode(payload.exposureMode)
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .configureTunnel:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCTunnelConfigurationRequest.self,
          from: request
        )
        let status = try await composition.configureTunnel(
          tunnelID: payload.tunnelID,
          runtimeKey: payload.runtimeKey
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: Self.tunnelStatus(status)
        )

      case .connectTunnel:
        let status = try await composition.connectTunnel()
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: Self.tunnelStatus(status)
        )

      case .disconnectTunnel:
        try await composition.disconnectTunnel()
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .clearTunnel:
        try await composition.clearTunnelConfiguration()
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
      }
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

  private func removeForwarder(taskID: TaskID) async {
    streams.removeForwarder(taskID)
  }

  private static func conversationPage(
    taskID: String,
    entries: [TaskConversationBuffer.Entry]
  ) -> IPCTaskConversationPage {
    IPCTaskConversationPage(
      taskID: taskID,
      messages: entries.map { entry in
        IPCTaskConversationMessage(
          messageID: nil,
          key: entry.key,
          role: entry.role.rawValue,
          kind: entry.kind.rawValue,
          content: entry.content,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments,
          final: entry.isFinal
        )
      }
    )
  }

  private static func encodePush(_ change: ConversationChange) -> Data? {
    let push = IPCTaskConversationPush(
      taskID: change.taskID.rawValue,
      key: change.key,
      role: change.role.rawValue,
      kind: change.kind.rawValue,
      delta: change.delta,
      baseContentLength: change.baseContentLength,
      fullContent: change.fullContent,
      final: change.final,
      toolName: change.toolName,
      toolStatus: change.toolStatus,
      toolArguments: change.toolArguments
    )
    guard let data = try? JSONEncoder().encode(push),
      data.count <= BridgeServiceIPC.maximumMessageBytes
    else {
      return nil
    }
    return data
  }

  private static func tunnelStatus(
    _ snapshot: ServiceTunnelSnapshot
  ) -> IPCTunnelStatus {
    IPCTunnelStatus(
      configured: snapshot.configured,
      enabled: snapshot.enabled,
      helperAvailable: snapshot.helperAvailable,
      tunnelID: snapshot.tunnelID,
      lifecycle: snapshot.lifecycle.rawValue,
      acceptsRemoteSubmissions: snapshot.acceptsRemoteSubmissions,
      actionRequired: snapshot.actionRequired
    )
  }

  private static func mcpExposureMode(
    _ mode: ServiceMCPExposureMode
  ) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func projectPolicy(
    read: String,
    write: String,
    network: String
  ) throws -> ProjectAccessPolicy {
    let values = [read, write, network]
    let allowed = Set([
      ProjectPermission.denied.rawValue,
      ProjectPermission.requiresLocalApproval.rawValue,
      ProjectPermission.allowed.rawValue,
    ])
    guard values.allSatisfy(allowed.contains) else {
      throw ServiceStoreError.invalidArgument("project.policy")
    }
    return ProjectAccessPolicy(
      read: ProjectPermission(rawValue: read),
      write: ProjectPermission(rawValue: write),
      network: ProjectPermission(rawValue: network)
    )
  }

  private static func workspaceCommands(
    _ commands: [IPCWorkspaceCommand]
  ) throws -> [ServiceWorkspaceCommand] {
    guard commands.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    return try commands.map { command in
      guard let risk = ServiceWorkspaceCommandRisk(rawValue: command.risk) else {
        throw ServiceStoreError.invalidArgument("workspaceCommand.risk")
      }
      return try ServiceWorkspaceCommand(
        id: command.commandID,
        name: command.name,
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: command.workingDirectory,
        requiresNetwork: command.requiresNetwork,
        risk: risk
      )
    }
  }

  private static func absoluteDirectoryURL(_ path: String) throws -> URL {
    guard !path.isEmpty,
      path.hasPrefix("/"),
      path.utf8.count <= 16_384,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("project.path")
    }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }

  private static func approvalSummary(
    _ approval: ExecutionApprovalRequest
  ) -> IPCApprovalSummary {
    IPCApprovalSummary(
      approvalID: approval.id,
      taskID: approval.taskID.rawValue,
      threadID: approval.binding.threadID,
      turnID: approval.binding.turnID,
      itemID: approval.itemID,
      kind: approval.kind.rawValue,
      title: approval.title,
      summary: approval.summary,
      displayCommand: approval.displayCommand,
      relativePaths: approval.relativePaths,
      reason: approval.reason
    )
  }

  private static func map(_ error: Error) -> BridgeServiceIPCError {
    if error is BridgeServiceIPCCodecError {
      return .init(code: "invalid_request", message: "The XPC request is invalid.")
    }
    if let error = error as? ServiceStoreError {
      switch error {
      case .unknownProject:
        return .init(code: "project_not_found", message: "The project is unavailable.")
      case .unknownTask:
        return .init(code: "task_not_found", message: "The task is unavailable.")
      case .activeWriteTaskExists:
        return .init(
          code: "busy",
          message: "The project already has an active write task.",
          retryable: true
        )
      case .idempotencyConflict, .duplicateTask:
        return .init(
          code: "idempotency_conflict",
          message: "The request identifier is already in use."
        )
      case .invalidArgument, .invalidTaskTransition, .immutableTaskChanged:
        return .init(
          code: "invalid_state",
          message: "The operation is invalid for the current state."
        )
      case .duplicateProject, .duplicateProjectRoot:
        return .init(
          code: "duplicate_project",
          message: "The project root is already registered."
        )
      case .corruptSchema, .corruptRecord, .unsupportedSchemaVersion, .storageFailure:
        return .init(
          code: "unavailable",
          message: "The local service store is unavailable.",
          retryable: true
        )
      }
    }
    if let error = error as? BridgeMCPQueryError {
      switch error {
      case .projectNotFound:
        return .init(code: "project_not_found", message: "The project is unavailable.")
      case .threadNotFound:
        return .init(code: "thread_not_found", message: "The Thread is unavailable.")
      case .taskNotFound:
        return .init(code: "task_not_found", message: "The task is unavailable.")
      case .pathDenied:
        return .init(code: "path_denied", message: "The path is not allowed.")
      case .turnMismatch:
        return .init(code: "turn_mismatch", message: "The active Turn changed.")
      case .busy:
        return .init(code: "busy", message: "The service is busy.", retryable: true)
      case .timeout:
        return .init(code: "timeout", message: "The operation timed out.", retryable: true)
      case .unavailable:
        return .init(
          code: "unavailable",
          message: "A local component is unavailable.",
          retryable: true
        )
      case .idempotencyConflict, .eventSequenceMismatch, .invalidTaskState, .contractRejected:
        return .init(
          code: "invalid_state",
          message: "The operation was rejected by local policy."
        )
      case .projectBusy(let detail):
        return .init(
          code: "project_busy",
          message: "The project workspace is busy.",
          retryable: true,
          owner: detail.owner,
          taskID: detail.taskID,
          operationID: detail.operationID,
          sessionID: detail.sessionID
        )
      case .fileRevisionConflict:
        return .init(
          code: "file_revision_conflict",
          message: "The file content does not match the expected revision.",
          retryable: true
        )
      case .pathForbidden:
        return .init(code: "path_forbidden", message: "The path is not allowed.")
      case .pathChanged:
        return .init(
          code: "path_changed",
          message: "The target changed after it was validated.",
          retryable: true
        )
      case .writeNotAllowed:
        return .init(
          code: "write_not_allowed", message: "The project does not allow remote writes.")
      case .approvalRequired(let approvalID):
        return .init(
          code: "approval_required",
          message: "The local user must approve this action.",
          retryable: true,
          operationID: approvalID
        )
      case .approvalExpired:
        return .init(
          code: "approval_expired",
          message: "The local approval expired.",
          retryable: true
        )
      case .invalidPatch:
        return .init(code: "invalid_patch", message: "The patch could not be parsed or applied.")
      case .notGitRepository:
        return .init(code: "not_git_repository", message: "The project is not a Git repository.")
      case .commandSessionNotFound:
        return .init(
          code: "command_session_not_found",
          message: "The command session is unavailable."
        )
      case .commandTimeout:
        return .init(
          code: "command_timeout",
          message: "The command exceeded its time limit.",
          retryable: true
        )
      case .commandDenied(let reason):
        return .init(
          code: "command_denied",
          message: "The requested command was denied: \(reason)"
        )
      case .outputLimitExceeded:
        return .init(
          code: "output_limit_exceeded",
          message: "The command output exceeded the bounded limit."
        )
      }
    }
    if error is TunnelConfigurationError {
      return .init(
        code: "invalid_tunnel_configuration",
        message: "The Tunnel configuration is invalid."
      )
    }
    if let error = error as? ServiceTunnelError {
      switch error {
      case .invalidRuntimeKey, .invalidStoredConfiguration:
        return .init(code: "invalid_tunnel_configuration", message: error.localizedDescription)
      case .notConfigured:
        return .init(code: "tunnel_not_configured", message: error.localizedDescription)
      case .helperUnavailable:
        return .init(code: "tunnel_helper_unavailable", message: error.localizedDescription)
      case .secretStoreUnavailable:
        return .init(code: "keychain_unavailable", message: error.localizedDescription)
      case .localMCPUnavailable, .serviceStopped, .startFailed:
        return .init(
          code: "tunnel_unavailable",
          message: error.localizedDescription,
          retryable: true
        )
      }
    }
    if error is ExecutionServiceError {
      return .init(
        code: "execution_failed",
        message: "The Codex operation failed.",
        retryable: true
      )
    }
    return .init(
      code: "internal_error",
      message: "The service operation failed.",
      retryable: true
    )
  }

  private static func deadline() -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: .seconds(20))
  }

  private static func fallbackFailure(
    requestID: String,
    code: String,
    message: String,
    retryable: Bool = false
  ) -> Data {
    if let response = try? BridgeServiceIPCCodec.failure(
      requestID: requestID,
      error: .init(code: code, message: message, retryable: retryable)
    ) {
      return response
    }
    let fallback =
      #"{"schema_version":1,"request_id":"invalid","payload":null,"error":{"#
      + #""code":"internal_error","message":"The service failed.","retryable":true}}"#
    return Data(fallback.utf8)
  }
}

private final class StreamRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var forwarders: [TaskID: Task<Void, Never>] = [:]
  private var subscriptionIDs: [TaskID: Int] = [:]

  func takeForwarder(_ taskID: TaskID) -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return forwarders.removeValue(forKey: taskID)
  }

  func takeSubscription(_ taskID: TaskID) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return subscriptionIDs.removeValue(forKey: taskID)
  }

  func put(taskID: TaskID, forwarder: Task<Void, Never>, subscriptionID: Int) {
    lock.lock()
    forwarders[taskID] = forwarder
    subscriptionIDs[taskID] = subscriptionID
    lock.unlock()
  }

  func removeForwarder(_ taskID: TaskID) {
    lock.lock()
    forwarders.removeValue(forKey: taskID)
    subscriptionIDs.removeValue(forKey: taskID)
    lock.unlock()
  }

  func takeAll() -> ([TaskID: Task<Void, Never>], [TaskID: Int]) {
    lock.lock()
    defer { lock.unlock() }
    let activeForwarders = forwarders
    let activeSubscriptions = subscriptionIDs
    forwarders.removeAll(keepingCapacity: false)
    subscriptionIDs.removeAll(keepingCapacity: false)
    return (activeForwarders, activeSubscriptions)
  }
}

private final class XPCRequestAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumConcurrent: Int
  private var active = 0

  init(maximumConcurrent: Int) {
    precondition(maximumConcurrent > 0)
    self.maximumConcurrent = maximumConcurrent
  }

  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard active < maximumConcurrent else { return false }
    active += 1
    return true
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    active -= 1
  }
}

private final class XPCReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var reply: ((Data) -> Void)?

  init(_ reply: @escaping (Data) -> Void) {
    self.reply = reply
  }

  func call(_ data: Data) {
    lock.lock()
    let callback = reply
    reply = nil
    lock.unlock()
    callback?(data)
  }
}
