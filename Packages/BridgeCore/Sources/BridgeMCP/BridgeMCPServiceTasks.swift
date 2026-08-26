import Foundation

public struct MCPServiceTaskEvent: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String

  public init(sequence: Int64, kind: String, summary: String, occurredAt: String) {
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case summary
    case occurredAt = "occurred_at"
  }
}

public struct MCPServiceTaskActivity: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String
  public let toolName: String?
  public let toolStatus: String?

  public init(
    sequence: Int64,
    kind: String,
    summary: String,
    occurredAt: String,
    toolName: String? = nil,
    toolStatus: String? = nil
  ) {
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
    self.toolName = toolName
    self.toolStatus = toolStatus
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case summary
    case occurredAt = "occurred_at"
    case toolName = "tool_name"
    case toolStatus = "tool_status"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sequence = try container.decode(Int64.self, forKey: .sequence)
    kind = try container.decode(String.self, forKey: .kind)
    summary = try container.decode(String.self, forKey: .summary)
    occurredAt = try container.decode(String.self, forKey: .occurredAt)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolStatus = try container.decodeIfPresent(String.self, forKey: .toolStatus)
  }
}

public struct MCPServiceTaskSnapshot: Codable, Equatable, Sendable {
  public let taskID: String
  public let projectID: String
  public let source: String?
  public let sourceClientID: String?
  public let status: String
  public let providerID: String?
  public let installationID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let threadID: String?
  public let turnID: String?
  public let providerSessionID: String?
  public let providerRunID: String?
  public let permissionMode: String?
  public let networkAccess: Bool
  public let currentStep: String?
  public let changedFiles: [String]
  public let recentEvents: [MCPServiceTaskEvent]
  public let recentActivity: [MCPServiceTaskActivity]
  public let recentActivityAvailable: Bool
  public let supervisorStatus: String
  public let supervisorSummary: String?
  public let localApprovalRequired: Bool
  public let resultSummary: String?
  public let failureCode: String?
  public let updatedAt: String

  public init(
    taskID: String,
    projectID: String,
    source: String? = nil,
    sourceClientID: String? = nil,
    status: String,
    providerID: String? = nil,
    installationID: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    threadID: String? = nil,
    turnID: String? = nil,
    providerSessionID: String? = nil,
    providerRunID: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    currentStep: String? = nil,
    changedFiles: [String] = [],
    recentEvents: [MCPServiceTaskEvent] = [],
    recentActivity: [MCPServiceTaskActivity] = [],
    recentActivityAvailable: Bool = true,
    supervisorStatus: String,
    supervisorSummary: String? = nil,
    localApprovalRequired: Bool,
    resultSummary: String? = nil,
    failureCode: String? = nil,
    updatedAt: String
  ) {
    self.taskID = taskID
    self.projectID = projectID
    self.source = source
    self.sourceClientID = sourceClientID
    self.status = status
    self.providerID = providerID
    self.installationID = installationID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.threadID = threadID
    self.turnID = turnID
    self.providerSessionID = providerSessionID
    self.providerRunID = providerRunID
    self.permissionMode = permissionMode
    self.networkAccess = networkAccess
    self.currentStep = currentStep
    self.changedFiles = changedFiles
    self.recentEvents = recentEvents
    self.recentActivity = recentActivity
    self.recentActivityAvailable = recentActivityAvailable
    self.supervisorStatus = supervisorStatus
    self.supervisorSummary = supervisorSummary
    self.localApprovalRequired = localApprovalRequired
    self.resultSummary = resultSummary
    self.failureCode = failureCode
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case projectID = "project_id"
    case source
    case sourceClientID = "source_client_id"
    case status
    case providerID = "provider_id"
    case installationID = "installation_id"
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case providerSessionID = "provider_session_id"
    case providerRunID = "provider_run_id"
    case permissionMode = "permission_mode"
    case networkAccess = "network_access"
    case currentStep = "current_step"
    case changedFiles = "changed_files"
    case recentEvents = "recent_events"
    case recentActivity = "recent_activity"
    case recentActivityAvailable = "recent_activity_available"
    case supervisorStatus = "supervisor_status"
    case supervisorSummary = "supervisor_summary"
    case localApprovalRequired = "local_approval_required"
    case resultSummary = "result_summary"
    case failureCode = "failure_code"
    case updatedAt = "updated_at"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    taskID = try container.decode(String.self, forKey: .taskID)
    projectID = try container.decode(String.self, forKey: .projectID)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    sourceClientID = try container.decodeIfPresent(String.self, forKey: .sourceClientID)
    status = try container.decode(String.self, forKey: .status)
    providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
    installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
    executionModel = try container.decodeIfPresent(String.self, forKey: .executionModel)
    executionEffort = try container.decodeIfPresent(String.self, forKey: .executionEffort)
    threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
    turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
    providerRunID = try container.decodeIfPresent(String.self, forKey: .providerRunID)
    permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
    networkAccess = try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false
    currentStep = try container.decodeIfPresent(String.self, forKey: .currentStep)
    changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
    recentEvents =
      try container.decodeIfPresent([MCPServiceTaskEvent].self, forKey: .recentEvents) ?? []
    recentActivity =
      try container.decodeIfPresent([MCPServiceTaskActivity].self, forKey: .recentActivity) ?? []
    recentActivityAvailable =
      try container.decodeIfPresent(Bool.self, forKey: .recentActivityAvailable) ?? true
    supervisorStatus = try container.decode(String.self, forKey: .supervisorStatus)
    supervisorSummary = try container.decodeIfPresent(String.self, forKey: .supervisorSummary)
    localApprovalRequired = try container.decode(Bool.self, forKey: .localApprovalRequired)
    resultSummary = try container.decodeIfPresent(String.self, forKey: .resultSummary)
    failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
  }
}

public struct MCPServiceTaskSubmission: Codable, Equatable, Sendable {
  public let projectID: String?
  public let prompt: String
  public let skillName: String?
  public let threadID: String?
  public let providerID: String?
  public let installationID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let modelOverride: Bool?
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: String?
  public let networkAccess: Bool
  public let acceptanceCriteria: [String]
  public let clientRequestID: String?

  public init(
    projectID: String? = nil,
    prompt: String,
    skillName: String? = nil,
    threadID: String? = nil,
    providerID: String? = nil,
    installationID: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    modelOverride: Bool? = nil,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    acceptanceCriteria: [String] = [],
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.prompt = prompt
    self.skillName = skillName
    self.threadID = threadID
    self.providerID = providerID
    self.installationID = installationID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.modelOverride = modelOverride
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.networkAccess = networkAccess
    self.acceptanceCriteria = acceptanceCriteria
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case prompt
    case skillName = "skill_name"
    case threadID = "thread_id"
    case providerID = "provider_id"
    case installationID = "installation_id"
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case modelOverride = "model_override"
    case supervisorModel = "supervisor_model"
    case supervisorEffort = "supervisor_effort"
    case permissionMode = "permission_mode"
    case networkAccess = "network_access"
    case acceptanceCriteria = "acceptance_criteria"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPServiceTaskSubmissionReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let reusedExistingTask: Bool
  public let localApprovalRequired: Bool

  public init(
    taskID: String,
    status: String,
    reusedExistingTask: Bool,
    localApprovalRequired: Bool
  ) {
    self.taskID = taskID
    self.status = status
    self.reusedExistingTask = reusedExistingTask
    self.localApprovalRequired = localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

public struct MCPServiceTaskMutationReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let accepted: Bool

  public init(taskID: String, status: String, accepted: Bool) {
    self.taskID = taskID
    self.status = status
    self.accepted = accepted
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case accepted
  }
}
