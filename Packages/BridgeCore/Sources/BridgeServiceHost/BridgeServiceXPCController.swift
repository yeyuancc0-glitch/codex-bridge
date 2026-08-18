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

  public init(
    composition: ServiceComposition,
    maximumConcurrentRequests: Int = 8
  ) {
    precondition(maximumConcurrentRequests > 0)
    self.composition = composition
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
    Task { [composition, admission] in
      let response = await Self.handle(decoded, composition: composition)
      admission.release()
      replyBox.call(response)
    }
  }

  private static func handle(
    _ request: BridgeServiceIPCRequest,
    composition: ServiceComposition
  ) async -> Data {
    do {
      switch request.operation {
      case .status:
        let status = try await composition.application.serviceStatus(
          deadline: deadline()
        )
        let endpoint = await composition.endpoint()?.localURL.absoluteString
        let exposureMode = try await composition.settings.exposureMode()
        let tunnel = await composition.tunnelStatus()
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCServiceStatusResponse(
            status: status,
            localMCPURL: endpoint,
            exposureMode: mcpExposureMode(exposureMode),
            tunnel: tunnelStatus(tunnel)
          )
        )

      case .listProjects:
        let page = try await composition.application.serviceProjects(
          cursor: nil,
          limit: 100,
          deadline: deadline()
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
        let policy = try projectPolicy(
          read: payload.readPermission,
          write: payload.writePermission,
          network: payload.networkPermission
        )
        let project = try await composition.projects.register(
          name: payload.name,
          rootURL: try absoluteDirectoryURL(payload.absolutePath),
          accessPolicy: policy
        )
        let detail = try await composition.application.serviceProject(
          projectID: project.id.rawValue,
          deadline: deadline()
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
          try projectPolicy(
            read: payload.readPermission,
            write: payload.writePermission,
            network: payload.networkPermission
          ),
          projectID: ProjectID(rawValue: payload.projectID)
        )
        let detail = try await composition.application.serviceProject(
          projectID: payload.projectID,
          deadline: deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: detail
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
        let models = try await composition.application.serviceModels(deadline: deadline())
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: models
        )

      case .getModelCatalog:
        let catalog = try await composition.application.serviceModelCatalog(
          deadline: deadline()
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
              supervisorEnabled: try await composition.settings.isSupervisorEnabled()
            )
          )
        )

      case .getModelPreferences:
        let preferences = try await composition.application.serviceModelPreferences(
          deadline: deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: IPCModelPreferences(
            executionModel: preferences.executionModel,
            executionEffort: preferences.executionEffort,
            supervisorModel: preferences.supervisorModel,
            supervisorEffort: preferences.supervisorEffort,
            supervisorEnabled: try await composition.settings.isSupervisorEnabled()
          )
        )

      case .setModelPreferences:
        let payload = try BridgeServiceIPCCodec.payload(
          IPCModelPreferences.self,
          from: request
        )
        try await composition.application.setServiceModelPreferences(
          ServiceModelPreferences(
            executionModel: payload.executionModel,
            executionEffort: payload.executionEffort,
            supervisorModel: payload.supervisorModel,
            supervisorEffort: payload.supervisorEffort
          ),
          deadline: deadline()
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
          deadline: deadline()
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
          deadline: deadline()
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
              deadline: deadline()
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
          deadline: deadline()
        )
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: task
        )

      case .approveTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        try await composition.application.approveTask(
          taskID: TaskID(rawValue: payload.taskID)
        )
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .rejectTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        try await composition.application.rejectTask(
          taskID: TaskID(rawValue: payload.taskID)
        )
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .stopTask:
        let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
        await composition.coordinator.stop(taskID: TaskID(rawValue: payload.taskID))
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
            approvals: approvals.map(approvalSummary)
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
          payload: tunnelStatus(status)
        )

      case .connectTunnel:
        let status = try await composition.connectTunnel()
        return try BridgeServiceIPCCodec.success(
          requestID: request.requestID,
          payload: tunnelStatus(status)
        )

      case .disconnectTunnel:
        try await composition.disconnectTunnel()
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)

      case .clearTunnel:
        try await composition.clearTunnelConfiguration()
        return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
      }
    } catch {
      let mapped = map(error)
      return fallbackFailure(
        requestID: request.requestID,
        code: mapped.code,
        message: mapped.message,
        retryable: mapped.retryable
      )
    }
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
