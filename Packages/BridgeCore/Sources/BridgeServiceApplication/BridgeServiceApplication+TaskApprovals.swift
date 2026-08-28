import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public struct PendingTaskStartApproval: Equatable, Sendable {
    public let approvalID: String
    public let taskID: String
    public let projectID: String
    public let clientID: String
    public let prompt: String
    public let providerID: String
    public let permissionMode: String
    public let networkAllowed: Bool

    public var providerDisplayName: String {
      ServiceAgentProviderPolicyRegistry.displayName(
        for: AgentProviderID(rawValue: providerID)
      )
    }

    public init(task: ServiceTaskRecord) {
      approvalID = Self.approvalID(for: task.id)
      taskID = task.id.rawValue
      projectID = task.projectID.rawValue
      clientID = task.source == .chatGPT ? MCPClientID.chatGPT.rawValue : task.sourceClientID
      prompt = task.prompt
      providerID = task.providerID
      permissionMode = task.permissionMode.rawValue
      networkAllowed = task.networkAllowed
    }

    public static func approvalID(for taskID: TaskID) -> String {
      "bridge-task-start:\(taskID.rawValue)"
    }
  }

  public func pendingTaskStartApprovals(taskID: TaskID? = nil) async throws
    -> [PendingTaskStartApproval]
  {
    let taskList: [ServiceTaskRecord]
    if let taskID {
      taskList = try await tasks.task(id: taskID).map { [$0] } ?? []
    } else {
      taskList = try await tasks.tasks(limit: 500)
    }
    return taskList.compactMap { task in
      guard task.state.status == .awaitingLocalApproval,
        task.requiresLocalStartApproval
      else {
        return nil
      }
      return PendingTaskStartApproval(task: task)
    }
  }

  public func resolveTaskStartApproval(
    taskID: TaskID,
    approvalID: String,
    approved: Bool,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard approvalID == PendingTaskStartApproval.approvalID(for: taskID),
      let task = try await tasks.task(id: taskID),
      task.state.status == .awaitingLocalApproval,
      task.requiresLocalStartApproval
    else {
      throw BridgeMCPQueryError.approvalExpired
    }
    if approved {
      try await approveAndStartTask(taskID)
    } else {
      do {
        _ = try await tasks.denyStart(taskID: taskID)
      } catch ServiceStoreError.invalidTaskTransition {
        throw BridgeMCPQueryError.approvalExpired
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      } catch {
        throw error
      }
    }
  }

  func submitTaskWithAdmission(
    _ request: ServiceTaskRequest,
    projectID: ProjectID
  ) async throws -> ServiceTaskCreationResult {
    // Read-only submissions never occupy the project write slot, so they do
    // not take the Codex admission token.
    if request.permissionMode == .readOnly {
      do {
        return try await tasks.submit(request)
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
    }
    let admissionToken: String
    do {
      admissionToken = try await workspaceGate.beginCodexAdmission(projectID: projectID)
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      let result = try await tasks.submit(request)
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      return result
    } catch {
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
  }

  func approveAndStartTask(
    _ taskID: TaskID,
    automatically: Bool = false
  ) async throws {
    let started: ServiceTaskRecord
    do {
      started = try await tasks.approveAndBegin(
        taskID: taskID,
        summary:
          automatically
          ? "The configured local policy automatically approved this provider invocation."
          : "The local user approved this provider invocation."
      )
    } catch ServiceStoreError.invalidTaskTransition {
      throw BridgeMCPQueryError.approvalExpired
    } catch let storeError as ServiceStoreError {
      throw Self.publicStoreError(storeError)
    } catch {
      throw error
    }
    do {
      try await coordinator.start(taskID: started.id)
    } catch {
      throw Self.publicExecutionError(error)
    }
  }

  public func pendingCodexApprovals(taskID: TaskID? = nil) async
    -> [ExecutionApprovalRequest]
  {
    await coordinator.pendingApprovals(taskID: taskID)
  }

  public func resolveCodexApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    try await coordinator.resolveApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision
    )
  }
}
