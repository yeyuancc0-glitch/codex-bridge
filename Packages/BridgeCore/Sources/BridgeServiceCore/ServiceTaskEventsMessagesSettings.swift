import BridgeDomain
import Foundation

public enum ServiceTaskEventKind: String, Codable, CaseIterable, Sendable {
  case taskCreated = "task.created"
  case taskApproved = "task.approved"
  case executionStarting = "execution.starting"
  case executionStarted = "execution.started"
  case planUpdated = "execution.plan_updated"
  case commandCompleted = "execution.command_completed"
  case fileChanged = "execution.file_changed"
  case approvalRequested = "approval.requested"
  case approvalResolved = "approval.resolved"
  case supervisorStarted = "supervisor.started"
  case supervisorDecision = "supervisor.decision"
  case supervisorDegraded = "supervisor.degraded"
  case turnCompleted = "execution.turn_completed"
  case taskCompleted = "task.completed"
  case taskFailed = "task.failed"
  case taskInterrupted = "task.interrupted"
  case taskMarkedUnknown = "task.marked_unknown"
}

public struct ServiceTaskEventDraft: Codable, Equatable, Sendable {
  public let kind: ServiceTaskEventKind
  public let summary: String
  public let createdAt: Date

  public init(kind: ServiceTaskEventKind, summary: String, createdAt: Date) throws {
    try ServiceValidation.text(summary, field: "taskEvent.summary", maximumBytes: 8 * 1_024)
    try ServiceValidation.date(createdAt, field: "taskEvent.createdAt")
    self.kind = kind
    self.summary = summary
    self.createdAt = createdAt
  }
}

public enum ServiceTaskMessageRole: String, Codable, CaseIterable, Sendable {
  case user
  case agent
}

public enum ServiceTaskMessageKind: String, Codable, CaseIterable, Sendable {
  case user
  case agent
  case reasoning
  case toolCall = "tool_call"
}

public struct ServiceTaskMessageDraft: Codable, Equatable, Sendable {
  public let key: String
  public let role: ServiceTaskMessageRole
  public let kind: ServiceTaskMessageKind
  public let content: String
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    key: String,
    role: ServiceTaskMessageRole,
    content: String,
    createdAt: Date,
    kind: ServiceTaskMessageKind = .agent,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    updatedAt: Date? = nil
  ) throws {
    try ServiceValidation.identifier(key, field: "taskMessage.key", maximumBytes: 256)
    try ServiceValidation.text(content, field: "taskMessage.content", maximumBytes: 256 * 1_024)
    try ServiceValidation.optionalText(toolName, field: "taskMessage.toolName", maximumBytes: 256)
    try ServiceValidation.optionalText(
      toolArguments,
      field: "taskMessage.toolArguments",
      maximumBytes: 64 * 1_024
    )
    try ServiceValidation.date(createdAt, field: "taskMessage.createdAt")
    let effectiveUpdatedAt = updatedAt ?? createdAt
    try ServiceValidation.date(effectiveUpdatedAt, field: "taskMessage.updatedAt")
    guard effectiveUpdatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("taskMessage.updatedAt")
    }
    self.key = key
    self.role = role
    self.kind = kind
    self.content = content
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
    self.createdAt = createdAt
    self.updatedAt = effectiveUpdatedAt
  }
}

public struct ServiceTaskMessageRecord: Codable, Equatable, Sendable {
  public let id: Int64
  public let taskID: TaskID
  public let key: String
  public let role: ServiceTaskMessageRole
  public let kind: ServiceTaskMessageKind
  public let content: String
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: Int64,
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    content: String,
    createdAt: Date,
    kind: ServiceTaskMessageKind = .agent,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    updatedAt: Date? = nil
  ) throws {
    guard id > 0 else { throw ServiceStoreError.invalidArgument("taskMessage.id") }
    try ServiceValidation.identifier(
      taskID.rawValue, field: "taskMessage.taskID", maximumBytes: 128)
    try ServiceValidation.identifier(key, field: "taskMessage.key", maximumBytes: 256)
    try ServiceValidation.text(content, field: "taskMessage.content", maximumBytes: 256 * 1_024)
    try ServiceValidation.optionalText(toolName, field: "taskMessage.toolName", maximumBytes: 256)
    try ServiceValidation.optionalText(
      toolArguments,
      field: "taskMessage.toolArguments",
      maximumBytes: 64 * 1_024
    )
    try ServiceValidation.date(createdAt, field: "taskMessage.createdAt")
    let effectiveUpdatedAt = updatedAt ?? createdAt
    try ServiceValidation.date(effectiveUpdatedAt, field: "taskMessage.updatedAt")
    guard effectiveUpdatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("taskMessage.updatedAt")
    }
    self.id = id
    self.taskID = taskID
    self.key = key
    self.role = role
    self.kind = kind
    self.content = content
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
    self.createdAt = createdAt
    self.updatedAt = effectiveUpdatedAt
  }

  /// A persisted message does not store its own finality. The task state is
  /// the authority for provider text, while user messages and completed tool
  /// calls remain independently complete during a running task.
  public func isFinal(for taskStatus: ServiceTaskStatus) -> Bool {
    if taskStatus.isTerminal || role == .user || kind == .user {
      return true
    }
    guard kind == .toolCall else { return false }
    switch toolStatus {
    case "completed", "failed", "declined", "cancelled":
      return true
    default:
      return false
    }
  }
}

public struct ServiceTaskEventRecord: Codable, Equatable, Sendable {
  public let id: Int64
  public let taskID: TaskID
  public let kind: ServiceTaskEventKind
  public let summary: String
  public let createdAt: Date

  public init(
    id: Int64,
    taskID: TaskID,
    kind: ServiceTaskEventKind,
    summary: String,
    createdAt: Date
  ) throws {
    guard id > 0 else { throw ServiceStoreError.invalidArgument("taskEvent.id") }
    try ServiceValidation.identifier(taskID.rawValue, field: "taskEvent.taskID", maximumBytes: 128)
    try ServiceValidation.text(summary, field: "taskEvent.summary", maximumBytes: 8 * 1_024)
    try ServiceValidation.date(createdAt, field: "taskEvent.createdAt")
    self.id = id
    self.taskID = taskID
    self.kind = kind
    self.summary = summary
    self.createdAt = createdAt
  }
}

public struct ServiceSettingRecord: Codable, Equatable, Sendable {
  public let key: String
  public let value: String
  public let updatedAt: Date

  public init(key: String, value: String, updatedAt: Date) throws {
    try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    try ServiceValidation.text(
      value,
      field: "setting.value",
      maximumBytes: 64 * 1_024,
      allowEmpty: true
    )
    try ServiceValidation.date(updatedAt, field: "setting.updatedAt")
    self.key = key
    self.value = value
    self.updatedAt = updatedAt
  }
}
