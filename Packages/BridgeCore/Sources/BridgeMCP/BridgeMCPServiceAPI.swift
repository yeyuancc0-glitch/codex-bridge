import Foundation

public enum MCPServiceExposureMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case full
}

public protocol BridgeMCPServiceAPI: Sendable {
  func serviceStatus(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot

  func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage

  func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail

  func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage

  func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage

  func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage

  func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage

  func serviceModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList

  func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot

  func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt

  func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt

  func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt
}

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
  public let projectID: String
  public let prompt: String
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
    projectID: String,
    prompt: String,
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
