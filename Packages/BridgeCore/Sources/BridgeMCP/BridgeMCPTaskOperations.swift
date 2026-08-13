import BridgeDomain
import Foundation

/// SDK-free boundary between the MCP adapter and the task application service.
public protocol BridgeMCPTaskOperations: Sendable {
  func getTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSnapshot

  func getTaskEvents(
    taskID: String,
    afterSequence: Int64?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskEventPage

  func getTaskDiff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage

  func getFinalReport(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFinalReport

  func submitTask(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt

  func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt

  func interruptTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt

  func interruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt
}

extension BridgeMCPTaskOperations {
  public func interruptTask(
    taskID: String,
    expectedTurnID _: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    throw BridgeMCPTaskOperationsCompatibilityError.expectedTurnUnsupported
  }
}

public enum BridgeMCPTaskOperationsCompatibilityError: Error, Equatable, Sendable {
  case expectedTurnUnsupported
}

public struct MCPTaskSnapshot: Codable, Equatable, Sendable {
  public let taskID: String
  public let phase: String
  public let activity: String
  public let threadID: String?
  public let turnID: String?
  public let currentPlan: [String]
  public let currentStep: String?
  public let supervisorState: String
  public let changedFileCount: Int
  public let verificationSummary: String?
  public let finalReportAvailable: Bool
  public let updatedAt: String?

  public init(
    taskID: String,
    phase: String,
    activity: String,
    threadID: String? = nil,
    turnID: String? = nil,
    currentPlan: [String] = [],
    currentStep: String? = nil,
    supervisorState: String,
    changedFileCount: Int = 0,
    verificationSummary: String? = nil,
    finalReportAvailable: Bool,
    updatedAt: String? = nil
  ) {
    self.taskID = taskID
    self.phase = phase
    self.activity = activity
    self.threadID = threadID
    self.turnID = turnID
    self.currentPlan = currentPlan
    self.currentStep = currentStep
    self.supervisorState = supervisorState
    self.changedFileCount = changedFileCount
    self.verificationSummary = verificationSummary
    self.finalReportAvailable = finalReportAvailable
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case phase
    case activity
    case threadID = "thread_id"
    case turnID = "turn_id"
    case currentPlan = "current_plan"
    case currentStep = "current_step"
    case supervisorState = "supervisor_state"
    case changedFileCount = "changed_file_count"
    case verificationSummary = "verification_summary"
    case finalReportAvailable = "final_report_available"
    case updatedAt = "updated_at"
  }
}

public struct MCPTaskEvent: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let occurredAt: String?
  public let summary: String?

  public init(sequence: Int64, kind: String, occurredAt: String? = nil, summary: String? = nil) {
    self.sequence = sequence
    self.kind = kind
    self.occurredAt = occurredAt
    self.summary = summary
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case occurredAt = "occurred_at"
    case summary
  }
}

public struct MCPTaskEventPage: Codable, Equatable, Sendable {
  public let taskID: String
  public let events: [MCPTaskEvent]
  public let nextAfterSequence: Int64?

  public init(taskID: String, events: [MCPTaskEvent], nextAfterSequence: Int64? = nil) {
    self.taskID = taskID
    self.events = events
    self.nextAfterSequence = nextAfterSequence
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case events
    case nextAfterSequence = "next_after_seq"
  }
}

public struct MCPTaskDiffFile: Codable, Equatable, Sendable {
  public let relativePath: String
  public let status: String
  public let additions: Int?
  public let deletions: Int?

  public init(
    relativePath: String,
    status: String,
    additions: Int? = nil,
    deletions: Int? = nil
  ) {
    self.relativePath = relativePath
    self.status = status
    self.additions = additions
    self.deletions = deletions
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case status
    case additions
    case deletions
  }
}

public struct MCPTaskDiffPage: Codable, Equatable, Sendable {
  public let taskID: String
  public let files: [MCPTaskDiffFile]
  public let diffStat: String
  public let patch: String?
  public let nextCursor: String?
  public let baselineWasDirty: Bool

  public init(
    taskID: String,
    files: [MCPTaskDiffFile],
    diffStat: String,
    patch: String? = nil,
    nextCursor: String? = nil,
    baselineWasDirty: Bool
  ) {
    self.taskID = taskID
    self.files = files
    self.diffStat = diffStat
    self.patch = patch
    self.nextCursor = nextCursor
    self.baselineWasDirty = baselineWasDirty
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case files
    case diffStat = "diff_stat"
    case patch
    case nextCursor = "next_cursor"
    case baselineWasDirty = "baseline_was_dirty"
  }
}

public struct MCPFinalReport: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let projectName: String
  public let threadID: String?
  public let executionModel: String
  public let executionEffort: String
  public let summary: String
  public let changedFiles: [String]
  public let diffStat: String
  public let commands: [String]
  public let verification: [String]
  public let warnings: [String]
  public let unresolvedItems: [String]
  public let commit: String?
  public let startedAt: String
  public let completedAt: String

  public init(
    taskID: String,
    status: String,
    projectName: String,
    threadID: String? = nil,
    executionModel: String,
    executionEffort: String,
    summary: String,
    changedFiles: [String] = [],
    diffStat: String,
    commands: [String] = [],
    verification: [String] = [],
    warnings: [String] = [],
    unresolvedItems: [String] = [],
    commit: String? = nil,
    startedAt: String,
    completedAt: String
  ) {
    self.taskID = taskID
    self.status = status
    self.projectName = projectName
    self.threadID = threadID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.summary = summary
    self.changedFiles = changedFiles
    self.diffStat = diffStat
    self.commands = commands
    self.verification = verification
    self.warnings = warnings
    self.unresolvedItems = unresolvedItems
    self.commit = commit
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case projectName = "project"
    case threadID = "thread_id"
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case summary
    case changedFiles = "changed_files"
    case diffStat = "diff_stat"
    case commands
    case verification
    case warnings
    case unresolvedItems = "unresolved_items"
    case commit
    case startedAt = "started_at"
    case completedAt = "completed_at"
  }
}

public struct MCPTaskSubmissionReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let phase: String
  public let reusedExistingTask: Bool
  public let localApprovalRequired: Bool

  public init(
    taskID: String,
    phase: String,
    reusedExistingTask: Bool,
    localApprovalRequired: Bool
  ) {
    self.taskID = taskID
    self.phase = phase
    self.reusedExistingTask = reusedExistingTask
    self.localApprovalRequired = localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case phase
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

public struct MCPTaskMutationReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let phase: String
  public let accepted: Bool
  public let operationID: String

  public init(taskID: String, phase: String, accepted: Bool, operationID: String) {
    self.taskID = taskID
    self.phase = phase
    self.accepted = accepted
    self.operationID = operationID
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case phase
    case accepted
    case operationID = "operation_id"
  }
}
