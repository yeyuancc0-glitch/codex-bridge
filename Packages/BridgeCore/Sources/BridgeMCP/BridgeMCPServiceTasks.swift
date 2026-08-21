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
public struct MCPServiceTaskSnapshot: Codable, Equatable, Sendable {
  public let taskID: String
  public let projectID: String
  public let source: String?
  public let sourceClientID: String?
  public let status: String
  public let threadID: String?
  public let turnID: String?
  public let currentStep: String?
  public let changedFiles: [String]
  public let recentEvents: [MCPServiceTaskEvent]
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
    threadID: String? = nil,
    turnID: String? = nil,
    currentStep: String? = nil,
    changedFiles: [String] = [],
    recentEvents: [MCPServiceTaskEvent] = [],
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
    self.threadID = threadID
    self.turnID = turnID
    self.currentStep = currentStep
    self.changedFiles = changedFiles
    self.recentEvents = recentEvents
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
    case threadID = "thread_id"
    case turnID = "turn_id"
    case currentStep = "current_step"
    case changedFiles = "changed_files"
    case recentEvents = "recent_events"
    case supervisorStatus = "supervisor_status"
    case supervisorSummary = "supervisor_summary"
    case localApprovalRequired = "local_approval_required"
    case resultSummary = "result_summary"
    case failureCode = "failure_code"
    case updatedAt = "updated_at"
  }
}

public struct MCPServiceTaskSubmission: Codable, Equatable, Sendable {
  public let projectID: String?
  public let prompt: String
  public let skillName: String?
  public let threadID: String?
  public let executionModel: String?
  public let executionEffort: String?
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
    executionModel: String? = nil,
    executionEffort: String? = nil,
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
    self.executionModel = executionModel
    self.executionEffort = executionEffort
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
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
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
