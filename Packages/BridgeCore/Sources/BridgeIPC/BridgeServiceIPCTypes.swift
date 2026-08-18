import BridgeMCP
import Foundation

public enum BridgeServiceIPCOperation: String, Codable, CaseIterable, Sendable {
  case status
  case listProjects = "list_projects"
  case registerProject = "register_project"
  case updateProjectPolicy = "update_project_policy"
  case removeProject = "remove_project"
  case listModels = "list_models"
  case getModelCatalog = "get_model_catalog"
  case getModelPreferences = "get_model_preferences"
  case setModelPreferences = "set_model_preferences"
  case setSupervisorEnabled = "set_supervisor_enabled"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listTasks = "list_tasks"
  case getTask = "get_task"
  case stopTask = "stop_task"
  case listApprovals = "list_approvals"
  case resolveApproval = "resolve_approval"
  case setExposureMode = "set_exposure_mode"
  case configureTunnel = "configure_tunnel"
  case connectTunnel = "connect_tunnel"
  case disconnectTunnel = "disconnect_tunnel"
  case clearTunnel = "clear_tunnel"
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

public struct IPCModelPreferences: Codable, Equatable, Sendable {
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String
  public let supervisorEffort: String
  public let supervisorEnabled: Bool
  public let accessMode: String
  public let fastModeEnabled: Bool

  public init(
    executionModel: String,
    executionEffort: String,
    supervisorModel: String,
    supervisorEffort: String,
    supervisorEnabled: Bool = true,
    accessMode: String = "request-approval",
    fastModeEnabled: Bool = false
  ) {
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.supervisorEnabled = supervisorEnabled
    self.accessMode = accessMode
    self.fastModeEnabled = fastModeEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case supervisorModel = "supervisor_model"
    case supervisorEffort = "supervisor_effort"
    case supervisorEnabled = "supervisor_enabled"
    case accessMode = "access_mode"
    case fastModeEnabled = "fast_mode_enabled"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.executionModel = try values.decode(String.self, forKey: .executionModel)
    self.executionEffort = try values.decode(String.self, forKey: .executionEffort)
    self.supervisorModel = try values.decode(String.self, forKey: .supervisorModel)
    self.supervisorEffort = try values.decode(String.self, forKey: .supervisorEffort)
    self.supervisorEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .supervisorEnabled) ?? true
    self.accessMode =
      try values.decodeIfPresent(String.self, forKey: .accessMode) ?? "request-approval"
    self.fastModeEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .fastModeEnabled) ?? false
  }
}

public struct IPCSupervisorEnabledRequest: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct IPCModelCatalogResponse: Codable, Equatable, Sendable {
  public let models: [MCPModelSummary]
  public let preferences: IPCModelPreferences

  public init(models: [MCPModelSummary], preferences: IPCModelPreferences) {
    self.models = models
    self.preferences = preferences
  }
}

public struct IPCTunnelConfigurationRequest: Codable, Equatable, Sendable {
  public let tunnelID: String
  public let runtimeKey: String

  public init(tunnelID: String, runtimeKey: String) {
    self.tunnelID = tunnelID
    self.runtimeKey = runtimeKey
  }

  private enum CodingKeys: String, CodingKey {
    case tunnelID = "tunnel_id"
    case runtimeKey = "runtime_key"
  }
}

public struct IPCTunnelStatus: Codable, Equatable, Sendable {
  public let configured: Bool
  public let enabled: Bool
  public let helperAvailable: Bool
  public let tunnelID: String?
  public let lifecycle: String
  public let acceptsRemoteSubmissions: Bool
  public let actionRequired: Bool

  public init(
    configured: Bool,
    enabled: Bool,
    helperAvailable: Bool,
    tunnelID: String?,
    lifecycle: String,
    acceptsRemoteSubmissions: Bool,
    actionRequired: Bool
  ) {
    self.configured = configured
    self.enabled = enabled
    self.helperAvailable = helperAvailable
    self.tunnelID = tunnelID
    self.lifecycle = lifecycle
    self.acceptsRemoteSubmissions = acceptsRemoteSubmissions
    self.actionRequired = actionRequired
  }

  private enum CodingKeys: String, CodingKey {
    case configured
    case enabled
    case helperAvailable = "helper_available"
    case tunnelID = "tunnel_id"
    case lifecycle
    case acceptsRemoteSubmissions = "accepts_remote_submissions"
    case actionRequired = "action_required"
  }
}

public struct IPCServiceStatusResponse: Codable, Equatable, Sendable {
  public let status: BridgeStatusSnapshot
  public let localMCPURL: String?
  public let exposureMode: MCPServiceExposureMode
  public let tunnel: IPCTunnelStatus

  public init(
    status: BridgeStatusSnapshot,
    localMCPURL: String?,
    exposureMode: MCPServiceExposureMode,
    tunnel: IPCTunnelStatus = .unconfigured
  ) {
    self.status = status
    self.localMCPURL = localMCPURL
    self.exposureMode = exposureMode
    self.tunnel = tunnel
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case localMCPURL = "local_mcp_url"
    case exposureMode = "exposure_mode"
    case tunnel
  }
}

extension IPCTunnelStatus {
  public static let unconfigured = IPCTunnelStatus(
    configured: false,
    enabled: false,
    helperAvailable: false,
    tunnelID: nil,
    lifecycle: "stopped",
    acceptsRemoteSubmissions: false,
    actionRequired: false
  )
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
