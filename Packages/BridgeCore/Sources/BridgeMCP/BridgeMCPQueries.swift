import Foundation

public protocol BridgeMCPQueries: Sendable {
  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot

  func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList
}

public enum BridgeMCPQueryError: Error, Equatable, Sendable {
  case projectNotFound
  case threadNotFound
  case pathDenied
  case taskNotFound
  case idempotencyConflict
  case turnMismatch
  case eventSequenceMismatch
  case invalidTaskState
  case contractRejected
  case busy
  case timeout
  case unavailable
  case projectBusy(WorkspaceBusyDetail)
}

public struct WorkspaceBusyDetail: Codable, Equatable, Sendable {
  public let owner: String
  public let taskID: String?
  public let operationID: String?
  public let sessionID: String?

  public init(
    owner: String,
    taskID: String? = nil,
    operationID: String? = nil,
    sessionID: String? = nil
  ) {
    self.owner = owner
    self.taskID = taskID
    self.operationID = operationID
    self.sessionID = sessionID
  }

  public static func codex(taskID: String) -> WorkspaceBusyDetail {
    WorkspaceBusyDetail(owner: "codex_task", taskID: taskID)
  }

  public static func codexAdmissionPending() -> WorkspaceBusyDetail {
    WorkspaceBusyDetail(owner: "codex_task", taskID: nil)
  }

  public static func direct(owner: String, operationID: String? = nil, sessionID: String? = nil)
    -> WorkspaceBusyDetail
  {
    WorkspaceBusyDetail(owner: owner, operationID: operationID, sessionID: sessionID)
  }
}

public struct BridgeStatusSnapshot: Codable, Equatable, Sendable {
  public let appVersion: String
  public let mcpState: String
  public let tunnelState: String
  public let codexVersion: String?
  public let loginMode: String?
  public let executionState: String
  public let supervisorState: String
  public let degradations: [String]
  public let pendingApprovalCount: Int

  public init(
    appVersion: String,
    mcpState: String,
    tunnelState: String,
    codexVersion: String? = nil,
    loginMode: String? = nil,
    executionState: String,
    supervisorState: String,
    degradations: [String] = [],
    pendingApprovalCount: Int
  ) {
    self.appVersion = appVersion
    self.mcpState = mcpState
    self.tunnelState = tunnelState
    self.codexVersion = codexVersion
    self.loginMode = loginMode
    self.executionState = executionState
    self.supervisorState = supervisorState
    self.degradations = degradations
    self.pendingApprovalCount = pendingApprovalCount
  }

  private enum CodingKeys: String, CodingKey {
    case appVersion = "app_version"
    case mcpState = "mcp_state"
    case tunnelState = "tunnel_state"
    case codexVersion = "codex_version"
    case loginMode = "login_mode"
    case executionState = "execution_state"
    case supervisorState = "supervisor_state"
    case degradations
    case pendingApprovalCount = "pending_approval_count"
  }
}

public struct MCPProjectCapabilities: Codable, Equatable, Sendable {
  public let read: String
  public let write: String
  public let network: String

  public init(read: String, write: String, network: String) {
    self.read = read
    self.write = write
    self.network = network
  }
}

public struct MCPProjectSummary: Codable, Equatable, Sendable {
  public let projectID: String
  public let name: String
  public let capabilities: MCPProjectCapabilities
  public let gitState: String?

  public init(
    projectID: String,
    name: String,
    capabilities: MCPProjectCapabilities,
    gitState: String? = nil
  ) {
    self.projectID = projectID
    self.name = name
    self.capabilities = capabilities
    self.gitState = gitState
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case name
    case capabilities
    case gitState = "git_state"
  }
}

public struct MCPProjectPage: Codable, Equatable, Sendable {
  public let projects: [MCPProjectSummary]
  public let nextCursor: String?

  public init(projects: [MCPProjectSummary], nextCursor: String? = nil) {
    self.projects = projects
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case projects
    case nextCursor = "next_cursor"
  }
}

public struct MCPThreadSummary: Codable, Equatable, Sendable {
  public let threadID: String
  public let title: String?
  public let status: String
  public let updatedAt: String?
  public let preview: String?

  public init(
    threadID: String,
    title: String? = nil,
    status: String,
    updatedAt: String? = nil,
    preview: String? = nil
  ) {
    self.threadID = threadID
    self.title = title
    self.status = status
    self.updatedAt = updatedAt
    self.preview = preview
  }

  private enum CodingKeys: String, CodingKey {
    case threadID = "thread_id"
    case title
    case status
    case updatedAt = "updated_at"
    case preview
  }
}

public struct MCPThreadPage: Codable, Equatable, Sendable {
  public let threads: [MCPThreadSummary]
  public let nextCursor: String?

  public init(threads: [MCPThreadSummary], nextCursor: String? = nil) {
    self.threads = threads
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case threads
    case nextCursor = "next_cursor"
  }
}

public enum MCPThreadDetail: String, Codable, Equatable, Sendable {
  case summary
  case full
}

public struct MCPThreadEntry: Codable, Equatable, Sendable {
  public let turnID: String
  public let role: String
  public let text: String
  public let status: String?

  public init(turnID: String, role: String, text: String, status: String? = nil) {
    self.turnID = turnID
    self.role = role
    self.text = text
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case turnID = "turn_id"
    case role
    case text
    case status
  }
}

public struct MCPThreadReadPage: Codable, Equatable, Sendable {
  public let thread: MCPThreadSummary
  public let detail: MCPThreadDetail
  public let entries: [MCPThreadEntry]
  public let nextCursor: String?

  public init(
    thread: MCPThreadSummary,
    detail: MCPThreadDetail,
    entries: [MCPThreadEntry],
    nextCursor: String? = nil
  ) {
    self.thread = thread
    self.detail = detail
    self.entries = entries
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case thread
    case detail
    case entries
    case nextCursor = "next_cursor"
  }
}

public struct MCPModelSummary: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let isDefault: Bool
  public let reasoningEfforts: [String]
  public let defaultReasoningEffort: String?
  public let serviceTiers: [String]
  public let additionalSpeedTiers: [String]

  public var supportsFastMode: Bool {
    serviceTiers.contains("fast") || additionalSpeedTiers.contains("fast")
  }

  public init(
    modelID: String,
    displayName: String,
    isDefault: Bool,
    reasoningEfforts: [String],
    defaultReasoningEffort: String? = nil,
    serviceTiers: [String] = [],
    additionalSpeedTiers: [String] = []
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.isDefault = isDefault
    self.reasoningEfforts = reasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.serviceTiers = serviceTiers
    self.additionalSpeedTiers = additionalSpeedTiers
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    modelID = try values.decode(String.self, forKey: .modelID)
    displayName = try values.decode(String.self, forKey: .displayName)
    isDefault = try values.decode(Bool.self, forKey: .isDefault)
    reasoningEfforts = try values.decode([String].self, forKey: .reasoningEfforts)
    defaultReasoningEffort = try values.decodeIfPresent(
      String.self, forKey: .defaultReasoningEffort)
    serviceTiers = try values.decodeIfPresent([String].self, forKey: .serviceTiers) ?? []
    additionalSpeedTiers =
      try values.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case displayName = "display_name"
    case isDefault = "is_default"
    case reasoningEfforts = "reasoning_efforts"
    case defaultReasoningEffort = "default_reasoning_effort"
    case serviceTiers = "service_tiers"
    case additionalSpeedTiers = "additional_speed_tiers"
  }
}

public struct MCPModelList: Codable, Equatable, Sendable {
  public let models: [MCPModelSummary]

  public init(models: [MCPModelSummary]) {
    self.models = models
  }
}
