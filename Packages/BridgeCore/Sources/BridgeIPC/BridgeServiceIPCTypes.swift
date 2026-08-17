import BridgeMCP
import Foundation

public enum BridgeServiceIPCOperation: String, Codable, CaseIterable, Sendable {
  case status
  case listProjects = "list_projects"
  case registerProject = "register_project"
  case updateProjectPolicy = "update_project_policy"
  case removeProject = "remove_project"
  case listModels = "list_models"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listTasks = "list_tasks"
  case getTask = "get_task"
  case approveTask = "approve_task"
  case rejectTask = "reject_task"
  case stopTask = "stop_task"
  case listApprovals = "list_approvals"
  case resolveApproval = "resolve_approval"
  case setExposureMode = "set_exposure_mode"
}

public struct BridgeServiceIPCRequest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let operation: BridgeServiceIPCOperation
  public let payload: Data?

  public init(
    requestID: String,
    operation: BridgeServiceIPCOperation,
    payload: Data? = nil,
    schemaVersion: Int = BridgeServiceIPC.schemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.operation = operation
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case operation
    case payload
  }
}

public struct BridgeServiceIPCError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String
  public let retryable: Bool

  public init(code: String, message: String, retryable: Bool = false) {
    self.code = code
    self.message = message
    self.retryable = retryable
  }
}

public struct BridgeServiceIPCResponse: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let payload: Data?
  public let error: BridgeServiceIPCError?

  public init(
    requestID: String,
    payload: Data? = nil,
    error: BridgeServiceIPCError? = nil,
    schemaVersion: Int = BridgeServiceIPC.schemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.payload = payload
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case requestID = "request_id"
    case payload
    case error
  }
}

public struct IPCProjectRegistrationRequest: Codable, Equatable, Sendable {
  public let name: String
  public let absolutePath: String
  public let readPermission: String
  public let writePermission: String
  public let networkPermission: String

  public init(
    name: String,
    absolutePath: String,
    readPermission: String = "allowed",
    writePermission: String = "requiresLocalApproval",
    networkPermission: String = "denied"
  ) {
    self.name = name
    self.absolutePath = absolutePath
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case absolutePath = "absolute_path"
    case readPermission = "read_permission"
    case writePermission = "write_permission"
    case networkPermission = "network_permission"
  }
}

public struct IPCProjectPolicyRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let readPermission: String
  public let writePermission: String
  public let networkPermission: String

  public init(
    projectID: String,
    readPermission: String,
    writePermission: String,
    networkPermission: String
  ) {
    self.projectID = projectID
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case readPermission = "read_permission"
    case writePermission = "write_permission"
    case networkPermission = "network_permission"
  }
}

public struct IPCProjectIDRequest: Codable, Equatable, Sendable {
  public let projectID: String

  public init(projectID: String) {
    self.projectID = projectID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
  }
}

public struct IPCThreadListRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let cursor: String?
  public let limit: Int
  public let search: String?

  public init(projectID: String, cursor: String? = nil, limit: Int = 100, search: String? = nil) {
    self.projectID = projectID
    self.cursor = cursor
    self.limit = limit
    self.search = search
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case cursor
    case limit
    case search
  }
}

public struct IPCThreadReadRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let threadID: String
  public let detail: MCPThreadDetail
  public let cursor: String?
  public let limit: Int

  public init(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail = .summary,
    cursor: String? = nil,
    limit: Int = 100
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.detail = detail
    self.cursor = cursor
    self.limit = limit
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case threadID = "thread_id"
    case detail
    case cursor
    case limit
  }
}

public struct IPCTaskListRequest: Codable, Equatable, Sendable {
  public let projectID: String?
  public let limit: Int

  public init(projectID: String? = nil, limit: Int = 100) {
    self.projectID = projectID
    self.limit = limit
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case limit
  }
}

public struct IPCTaskRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let recentEventLimit: Int

  public init(taskID: String, recentEventLimit: Int = 50) {
    self.taskID = taskID
    self.recentEventLimit = recentEventLimit
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case recentEventLimit = "recent_event_limit"
  }
}

public struct IPCApprovalListRequest: Codable, Equatable, Sendable {
  public let taskID: String?

  public init(taskID: String? = nil) {
    self.taskID = taskID
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
  }
}

public struct IPCApprovalResolutionRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let approvalID: String
  public let decision: String

  public init(taskID: String, approvalID: String, decision: String) {
    self.taskID = taskID
    self.approvalID = approvalID
    self.decision = decision
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case approvalID = "approval_id"
    case decision
  }
}

public struct IPCExposureModeRequest: Codable, Equatable, Sendable {
  public let exposureMode: MCPServiceExposureMode

  public init(exposureMode: MCPServiceExposureMode) {
    self.exposureMode = exposureMode
  }

  private enum CodingKeys: String, CodingKey {
    case exposureMode = "exposure_mode"
  }
}

public struct IPCProjectListResponse: Codable, Equatable, Sendable {
  public let projects: [MCPProjectSummary]

  public init(projects: [MCPProjectSummary]) {
    self.projects = projects
  }
}

public struct IPCTaskListResponse: Codable, Equatable, Sendable {
  public let tasks: [MCPServiceTaskSnapshot]

  public init(tasks: [MCPServiceTaskSnapshot]) {
    self.tasks = tasks
  }
}

public struct IPCApprovalSummary: Codable, Equatable, Sendable {
  public let approvalID: String
  public let taskID: String
  public let threadID: String
  public let turnID: String
  public let itemID: String
  public let kind: String
  public let title: String
  public let summary: String
  public let displayCommand: String?
  public let relativePaths: [String]
  public let reason: String?

  public init(
    approvalID: String,
    taskID: String,
    threadID: String,
    turnID: String,
    itemID: String,
    kind: String,
    title: String,
    summary: String,
    displayCommand: String? = nil,
    relativePaths: [String] = [],
    reason: String? = nil
  ) {
    self.approvalID = approvalID
    self.taskID = taskID
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.kind = kind
    self.title = title
    self.summary = summary
    self.displayCommand = displayCommand
    self.relativePaths = relativePaths
    self.reason = reason
  }

  private enum CodingKeys: String, CodingKey {
    case approvalID = "approval_id"
    case taskID = "task_id"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case itemID = "item_id"
    case kind
    case title
    case summary
    case displayCommand = "display_command"
    case relativePaths = "relative_paths"
    case reason
  }
}

public struct IPCApprovalListResponse: Codable, Equatable, Sendable {
  public let approvals: [IPCApprovalSummary]

  public init(approvals: [IPCApprovalSummary]) {
    self.approvals = approvals
  }
}

public struct IPCMutationResponse: Codable, Equatable, Sendable {
  public let accepted: Bool

  public init(accepted: Bool = true) {
    self.accepted = accepted
  }
}
