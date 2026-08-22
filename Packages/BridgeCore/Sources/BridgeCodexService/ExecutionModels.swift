import BridgeCodexRPC
import BridgeDomain
import BridgeServiceCore
import Foundation

public struct ExecutionManagerConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let turnStartTimeoutNanoseconds: UInt64
  public let maximumSessionNanoseconds: UInt64
  public let eventBufferLimit: Int
  public let outputBufferLimit: Int
  public let maximumConcurrentSessions: Int
  public let maximumPendingApprovals: Int
  public let maximumKnownItems: Int

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
    turnStartTimeoutNanoseconds: UInt64 = 10_000_000_000,
    maximumSessionNanoseconds: UInt64 = 6 * 60 * 60 * 1_000_000_000,
    eventBufferLimit: Int = 256,
    outputBufferLimit: Int = 128,
    maximumConcurrentSessions: Int = 4,
    maximumPendingApprovals: Int = 16,
    maximumKnownItems: Int = 2_048
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.turnStartTimeoutNanoseconds = max(1, turnStartTimeoutNanoseconds)
    self.maximumSessionNanoseconds = max(1, maximumSessionNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.outputBufferLimit = max(1, outputBufferLimit)
    self.maximumConcurrentSessions = max(1, maximumConcurrentSessions)
    self.maximumPendingApprovals = max(1, maximumPendingApprovals)
    self.maximumKnownItems = max(1, maximumKnownItems)
  }
}

public enum ExecutionServiceError: Error, Equatable, LocalizedError, Sendable {
  case invalidRequest(String)
  case activeSession(TaskID)
  case sessionLimitReached
  case sessionUnavailable(TaskID)
  case sessionEnded(TaskID)
  case projectUnavailable(ProjectID)
  case projectIdentityChanged(ProjectID)
  case projectPermissionDenied(ProjectID)
  case modelUnavailable(String)
  case effortUnavailable(String)
  case serviceTierUnavailable(String)
  case threadUnavailable(String)
  case threadMismatch(String)
  case turnUnavailable
  case turnStartTimedOut
  case bindingMismatch
  case approvalUnavailable(String)
  case approvalExceedsPolicy
  case conversationPersistenceFailed
  case protocolViolation(String)
  case processUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let field):
      "The execution request is invalid: \(field)."
    case .activeSession:
      "The task already has an active Codex session."
    case .sessionLimitReached:
      "The Codex session limit was reached."
    case .sessionUnavailable:
      "The Codex session is unavailable."
    case .sessionEnded:
      "The Codex session has ended."
    case .projectUnavailable:
      "The project is unavailable."
    case .projectIdentityChanged:
      "The project root identity changed."
    case .projectPermissionDenied:
      "The project policy does not allow this execution."
    case .modelUnavailable(let model):
      "The selected Codex model is unavailable: \(model)."
    case .effortUnavailable(let effort):
      "The selected reasoning effort is unavailable: \(effort)."
    case .serviceTierUnavailable(let tier):
      "The selected service tier is unavailable: \(tier)."
    case .threadUnavailable:
      "The requested Codex Thread is unavailable."
    case .threadMismatch:
      "The Codex Thread does not belong to the selected project."
    case .turnUnavailable:
      "Codex could not start the task Turn."
    case .turnStartTimedOut:
      "Codex did not confirm the task Turn in time."
    case .bindingMismatch:
      "The Codex Thread or Turn did not match the active task."
    case .approvalUnavailable:
      "The Codex approval request is unavailable."
    case .approvalExceedsPolicy:
      "The Codex approval request exceeds the project or task policy."
    case .conversationPersistenceFailed:
      "The task conversation could not be persisted."
    case .protocolViolation(let message):
      "Codex returned an invalid protocol event: \(message)."
    case .processUnavailable:
      "The Codex app-server process is unavailable."
    }
  }
}

public struct ExecutionBinding: Codable, Equatable, Hashable, Sendable {
  public let threadID: String
  public let turnID: String

  public init(threadID: String, turnID: String) throws {
    try ExecutionValidation.identifier(threadID, field: "binding.threadID", maximumBytes: 1_024)
    try ExecutionValidation.identifier(turnID, field: "binding.turnID", maximumBytes: 1_024)
    self.threadID = threadID
    self.turnID = turnID
  }
}

public struct ExecutionRequest: Equatable, Sendable {
  public let task: ServiceTaskRecord
  public let project: ServiceProjectRecord

  public init(task: ServiceTaskRecord, project: ServiceProjectRecord) throws {
    guard task.projectID == project.id else {
      throw ExecutionServiceError.invalidRequest("projectID")
    }
    guard task.state.status == .starting else {
      throw ExecutionServiceError.invalidRequest("task.status")
    }
    self.task = task
    self.project = project
  }
}

public enum ExecutionCommandStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case declined
}

public enum ExecutionFileChangeStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case declined
}

public enum ExecutionApprovalKind: String, Codable, Equatable, Sendable {
  case command
  case fileChange = "file_change"
  case permissions
}

public enum LocalApprovalDecision: String, Codable, Equatable, Sendable {
  case allow
  case deny
}

public struct ExecutionApprovalRequest: Codable, Equatable, Sendable {
  public let id: String
  public let taskID: TaskID
  public let binding: ExecutionBinding
  public let itemID: String
  public let kind: ExecutionApprovalKind
  public let title: String
  public let summary: String
  public let displayCommand: String?
  public let relativePaths: [String]
  public let reason: String?

  public init(
    id: String,
    taskID: TaskID,
    binding: ExecutionBinding,
    itemID: String,
    kind: ExecutionApprovalKind,
    title: String,
    summary: String,
    displayCommand: String? = nil,
    relativePaths: [String] = [],
    reason: String? = nil
  ) throws {
    try ExecutionValidation.identifier(id, field: "approval.id", maximumBytes: 128)
    try ExecutionValidation.identifier(itemID, field: "approval.itemID", maximumBytes: 256)
    try ExecutionValidation.text(title, field: "approval.title", maximumBytes: 512)
    try ExecutionValidation.text(summary, field: "approval.summary", maximumBytes: 4 * 1_024)
    try ExecutionValidation.optionalText(
      displayCommand,
      field: "approval.displayCommand",
      maximumBytes: 8 * 1_024
    )
    try ExecutionValidation.relativePaths(relativePaths, field: "approval.relativePaths")
    try ExecutionValidation.optionalText(reason, field: "approval.reason", maximumBytes: 4 * 1_024)
    self.id = id
    self.taskID = taskID
    self.binding = binding
    self.itemID = itemID
    self.kind = kind
    self.title = title
    self.summary = summary
    self.displayCommand = displayCommand
    self.relativePaths = relativePaths
    self.reason = reason
  }
}

public struct ExecutionAgentMessage: Codable, Equatable, Sendable {
  public let key: String
  public let role: ServiceTaskMessageRole
  public let kind: ServiceTaskMessageKind
  public let content: String
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?

  public init(
    key: String,
    role: ServiceTaskMessageRole,
    kind: ServiceTaskMessageKind = .agent,
    content: String,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil
  ) throws {
    try ExecutionValidation.identifier(key, field: "agentMessage.key", maximumBytes: 256)
    try ExecutionValidation.text(content, field: "agentMessage.content", maximumBytes: 256 * 1_024)
    try ExecutionValidation.optionalText(
      toolName, field: "agentMessage.toolName", maximumBytes: 256)
    try ExecutionValidation.optionalText(
      toolArguments,
      field: "agentMessage.toolArguments",
      maximumBytes: 64 * 1_024
    )
    self.key = key
    self.role = role
    self.kind = kind
    self.content = content
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
  }
}

public struct ExecutionAgentMessageDelta: Codable, Equatable, Sendable {
  public let threadID: String
  public let turnID: String
  public let itemID: String
  public let delta: String

  public init(threadID: String, turnID: String, itemID: String, delta: String) throws {
    try ExecutionValidation.identifier(
      threadID,
      field: "agentMessageDelta.threadID",
      maximumBytes: 1_024
    )
    try ExecutionValidation.identifier(
      turnID,
      field: "agentMessageDelta.turnID",
      maximumBytes: 1_024
    )
    try ExecutionValidation.identifier(itemID, field: "agentMessageDelta.itemID", maximumBytes: 256)
    try ExecutionValidation.streamDelta(
      delta,
      field: "agentMessageDelta.delta",
      maximumBytes: 64 * 1_024
    )
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.delta = delta
  }
}

public struct ExecutionReasoningDelta: Codable, Equatable, Sendable {
  public let threadID: String
  public let turnID: String
  public let itemID: String
  public let delta: String

  public init(threadID: String, turnID: String, itemID: String, delta: String) throws {
    try ExecutionValidation.identifier(
      threadID,
      field: "reasoningDelta.threadID",
      maximumBytes: 1_024
    )
    try ExecutionValidation.identifier(
      turnID,
      field: "reasoningDelta.turnID",
      maximumBytes: 1_024
    )
    try ExecutionValidation.identifier(itemID, field: "reasoningDelta.itemID", maximumBytes: 256)
    try ExecutionValidation.streamDelta(
      delta,
      field: "reasoningDelta.delta",
      maximumBytes: 64 * 1_024
    )
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.delta = delta
  }
}

public enum ExecutionToolCallStatus: String, Codable, Equatable, Sendable {
  case inProgress
  case completed
  case failed
}

public struct ExecutionToolCall: Codable, Equatable, Sendable {
  public let itemID: String
  public let tool: String
  public let arguments: String?
  public let status: ExecutionToolCallStatus

  public init(
    itemID: String,
    tool: String,
    arguments: String?,
    status: ExecutionToolCallStatus
  ) throws {
    try ExecutionValidation.identifier(itemID, field: "toolCall.itemID", maximumBytes: 256)
    try ExecutionValidation.text(tool, field: "toolCall.tool", maximumBytes: 256)
    try ExecutionValidation.optionalText(
      arguments,
      field: "toolCall.arguments",
      maximumBytes: 64 * 1_024
    )
    self.itemID = itemID
    self.tool = tool
    self.arguments = arguments
    self.status = status
  }
}

public enum ExecutionEvent: Equatable, Sendable {
  case planUpdated(currentStep: String, steps: [String])
  case commandCompleted(
    displayCommand: String,
    exitCode: Int32?,
    status: ExecutionCommandStatus
  )
  case filesChanged(relativePaths: [String], status: ExecutionFileChangeStatus)
  case approvalRequested(ExecutionApprovalRequest)
  case agentMessageDelta(ExecutionAgentMessageDelta)
  case reasoningDelta(ExecutionReasoningDelta)
  case toolCall(ExecutionToolCall)
  case toolCallProgress(itemID: String, progress: String)
  case turnCompleted(messages: [ExecutionAgentMessage])
  case completed(resultSummary: String)
  case interrupted
  case failed(code: String, summary: String)
}

public struct ExecutionHandle: Sendable {
  public let taskID: TaskID
  public let binding: ExecutionBinding
  public let events: AsyncStream<ExecutionEvent>

  public init(taskID: TaskID, binding: ExecutionBinding, events: AsyncStream<ExecutionEvent>) {
    self.taskID = taskID
    self.binding = binding
    self.events = events
  }
}
