import BridgeMCP
import Foundation

public enum BridgeServiceIPCOperation: String, Codable, CaseIterable, Sendable {
  case status
  case listProjects = "list_projects"
  case registerProject = "register_project"
  case updateProjectPolicy = "update_project_policy"
  case removeProject = "remove_project"
  case getProjectCommands = "get_project_commands"
  case updateProjectCommands = "update_project_commands"
  case setProjectCommandMode = "set_project_command_mode"
  case listModels = "list_models"
  case getModelCatalog = "get_model_catalog"
  case getModelPreferences = "get_model_preferences"
  case setModelPreferences = "set_model_preferences"
  case setSupervisorEnabled = "set_supervisor_enabled"
  case listThreads = "list_threads"
  case listSkills = "list_skills"
  case readThread = "read_thread"
  case listTasks = "list_tasks"
  case getTask = "get_task"
  case stopTask = "stop_task"
  case deleteTask = "delete_task"
  case getTaskConversation = "get_task_conversation"
  case subscribeTaskConversation = "subscribe_task_conversation"
  case unsubscribeTaskConversation = "unsubscribe_task_conversation"
  case listApprovals = "list_approvals"
  case resolveApproval = "resolve_approval"
  case listDirectApprovals = "list_direct_approvals"
  case approveDirectApproval = "approve_direct_approval"
  case denyDirectApproval = "deny_direct_approval"
  case getDirectApprovalMode = "get_direct_approval_mode"
  case setDirectApprovalMode = "set_direct_approval_mode"
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
  public let owner: String?
  public let taskID: String?
  public let operationID: String?
  public let sessionID: String?

  public init(
    code: String,
    message: String,
    retryable: Bool = false,
    owner: String? = nil,
    taskID: String? = nil,
    operationID: String? = nil,
    sessionID: String? = nil
  ) {
    self.code = code
    self.message = message
    self.retryable = retryable
    self.owner = owner
    self.taskID = taskID
    self.operationID = operationID
    self.sessionID = sessionID
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case retryable
    case owner
    case taskID = "task_id"
    case operationID = "operation_id"
    case sessionID = "session_id"
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

public struct IPCMutationResponse: Codable, Equatable, Sendable {
  public let accepted: Bool

  public init(accepted: Bool = true) {
    self.accepted = accepted
  }
}
