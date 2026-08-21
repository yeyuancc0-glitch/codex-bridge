import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension BridgeServiceXPCController {
  static func conversationPage(
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

  static func encodePush(_ change: ConversationChange) -> Data? {
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

  static func tunnelStatus(
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

  static func mcpExposureMode(
    _ mode: ServiceMCPExposureMode
  ) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  static func projectPolicy(
    read: String,
    write: String,
    network: String
  ) throws -> ProjectAccessPolicy {
    guard read != ProjectPermission.requiresLocalApproval.rawValue else {
      throw ServiceStoreError.invalidArgument("project.policy.read")
    }
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

  static func workspaceCommands(
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

  static func blacklistRules(
    _ rules: [IPCBlacklistRule]
  ) throws -> [ServiceCommandBlacklistRule] {
    guard rules.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    return try rules.map { rule in
      try ServiceCommandBlacklistRule(
        id: rule.ruleID,
        executable: rule.executable,
        pattern: rule.pattern
      )
    }
  }

  static func absoluteDirectoryURL(_ path: String) throws -> URL {
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

  static func approvalSummary(
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

  static func map(_ error: Error) -> BridgeServiceIPCError {
    if error is BridgeServiceIPCCodecError {
      return .init(code: "invalid_request", message: "The XPC request is invalid.")
    }
    if let error = error as? ServiceLocalMCPError {
      switch error {
      case .localPortUnavailable:
        return .init(
          code: "local_port_unavailable",
          message: "The configured local MCP port is unavailable.",
          retryable: true
        )
      case .endpointManagedByConfiguration:
        return .init(
          code: "endpoint_managed_by_configuration",
          message: "The local MCP endpoint is managed by the service configuration."
        )
      }
    }
    if let error = error as? ServiceMCPClientRegistryError {
      switch error {
      case .unsupportedClient:
        return .init(code: "invalid_client", message: "The MCP client is unsupported.")
      case .clientDisabled:
        return .init(code: "client_disabled", message: "The MCP client is disabled.")
      }
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
      case .skillNotFound:
        return .init(code: "skill_not_found", message: "The Skill is unavailable.")
      case .skillActionNotFound:
        return .init(
          code: "skill_action_not_found", message: "The requested Skill action does not exist.")
      case .skillActionNotRunnable:
        return .init(
          code: "skill_action_not_runnable",
          message: "The requested Skill action cannot be launched."
        )
      case .threadNotFound:
        return .init(code: "thread_not_found", message: "The Thread is unavailable.")
      case .taskNotFound:
        return .init(code: "task_not_found", message: "The task is unavailable.")
      case .pathDenied:
        return .init(code: "path_denied", message: "The path is not allowed.")
      case .pathNotFound:
        return .init(code: "path_not_found", message: "The path does not exist.")
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
      case .revisionConflict:
        return .init(
          code: "revision_conflict",
          message: "The file changed since the expected revision.",
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
      case .approvalDenied:
        return .init(
          code: "approval_denied",
          message: "The local user denied this action.",
          retryable: true
        )
      case .invalidPatch:
        return .init(
          code: "invalid_patch",
          message:
            "The patch syntax was invalid or its exact context did not match. Read the file, then "
            + "use *** Update File with space/-/+ lines, *** Add File with + lines, or a standard "
            + "---/+++ unified diff."
        )
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
      case .processLaunchFailed:
        return .init(
          code: "process_launch_failed",
          message: "The command could not be launched.",
          retryable: true
        )
      case .gitOperationFailed(let summary):
        return .init(
          code: "git_operation_failed",
          message: "The git operation failed: \(summary)",
          retryable: true
        )
      case .outputLimitExceeded:
        return .init(
          code: "output_limit_exceeded",
          message: "The command output exceeded the bounded limit."
        )
      case .durabilityUncertain:
        return .init(
          code: "durability_uncertain",
          message:
            "The mutation was applied, but crash durability was not confirmed. Read the path before retrying."
        )
      case .networkIsolationUnavailable:
        return .init(
          code: "network_isolation_unavailable",
          message: "Network isolation could not be applied for this Skill action."
        )
      case .unsafeContentDetected:
        return .init(
          code: "unsafe_content_detected",
          message: "The content contains restricted credential material."
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

  static func deadline() -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: .seconds(20))
  }

  static func fallbackFailure(
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

struct StreamRegistration: Sendable {
  let forwarder: Task<Void, Never>
  let subscriptionID: Int
}

final class StreamRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var registrations: [TaskID: StreamRegistration] = [:]

  func take(_ taskID: TaskID) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    return registrations.removeValue(forKey: taskID)
  }

  func take(_ taskID: TaskID, subscriptionID: Int) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    guard registrations[taskID]?.subscriptionID == subscriptionID else { return nil }
    return registrations.removeValue(forKey: taskID)
  }

  @discardableResult
  func install(taskID: TaskID, registration: StreamRegistration) -> StreamRegistration? {
    lock.lock()
    let previous = registrations.updateValue(registration, forKey: taskID)
    lock.unlock()
    return previous
  }

  func takeAll() -> [TaskID: StreamRegistration] {
    lock.lock()
    defer { lock.unlock() }
    let active = registrations
    registrations.removeAll(keepingCapacity: false)
    return active
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return registrations.count
  }
}

final class AsyncMutex: @unchecked Sendable {
  private let stateLock = NSLock()
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    await withCheckedContinuation { continuation in
      stateLock.lock()
      if locked {
        waiters.append(continuation)
        stateLock.unlock()
        return
      }
      locked = true
      stateLock.unlock()
      continuation.resume()
    }
  }

  func release() {
    stateLock.lock()
    let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
    if waiter == nil { locked = false }
    stateLock.unlock()
    waiter?.resume()
  }
}

final class XPCRequestAdmission: @unchecked Sendable {
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

final class XPCReplyBox: @unchecked Sendable {
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
