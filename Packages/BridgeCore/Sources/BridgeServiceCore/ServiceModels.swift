import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation

public enum ServiceStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidArgument(String)
  case corruptSchema
  case corruptRecord
  case unsupportedSchemaVersion(Int64)
  case duplicateProject(ProjectID)
  case duplicateProjectRoot(String)
  case unknownProject(ProjectID)
  case duplicateTask(TaskID)
  case unknownTask(TaskID)
  case activeWriteTaskExists(ProjectID)
  case idempotencyConflict(source: ServiceTaskSource, clientRequestID: String)
  case immutableTaskChanged(TaskID)
  case invalidTaskTransition(from: ServiceTaskStatus, to: ServiceTaskStatus)
  case storageFailure

  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let field):
      "The service value is invalid: \(field)."
    case .corruptSchema:
      "The service database schema is corrupt."
    case .corruptRecord:
      "The service database contains an invalid record."
    case .unsupportedSchemaVersion(let version):
      "The service database schema version is unsupported: \(version)."
    case .duplicateProject:
      "The project identifier is already registered."
    case .duplicateProjectRoot:
      "The project root is already registered."
    case .unknownProject:
      "The project is not registered."
    case .duplicateTask:
      "The task identifier is already in use."
    case .unknownTask:
      "The task does not exist."
    case .activeWriteTaskExists:
      "The project already has an active write task."
    case .idempotencyConflict:
      "The client request identifier was reused with a different task."
    case .immutableTaskChanged:
      "Immutable task fields cannot be changed."
    case .invalidTaskTransition(let source, let destination):
      "The task cannot transition from \(source.rawValue) to \(destination.rawValue)."
    case .storageFailure:
      "The service database operation failed."
    }
  }
}

public struct ServiceRootIdentity: Codable, Equatable, Hashable, Sendable {
  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64

  public init(canonicalPath: String, device: UInt64, inode: UInt64) throws {
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16_384,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("project.root")
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
  }

  public init(capturing url: URL) throws {
    let root = try RegisteredRoot(capturing: url)
    try self.init(
      canonicalPath: root.canonicalPath,
      device: root.identity.device,
      inode: root.identity.inode
    )
  }

  public func validateCurrentIdentity() throws {
    let current = try ServiceRootIdentity(
      capturing: URL(fileURLWithPath: canonicalPath, isDirectory: true)
    )
    guard current == self else {
      throw ServiceStoreError.invalidArgument("project.rootIdentity")
    }
  }
}

public struct ServiceProjectRecord: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let name: String
  public let root: ServiceRootIdentity
  public let accessPolicy: ProjectAccessPolicy
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: ProjectID,
    name: String,
    root: ServiceRootIdentity,
    accessPolicy: ProjectAccessPolicy,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.identifier(id.rawValue, field: "project.id", maximumBytes: 128)
    try ServiceValidation.text(name, field: "project.name", maximumBytes: 1_024)
    try ServiceValidation.projectPolicy(accessPolicy)
    try ServiceValidation.date(createdAt, field: "project.createdAt")
    try ServiceValidation.date(updatedAt, field: "project.updatedAt")
    guard updatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("project.updatedAt")
    }
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.root = root
    self.accessPolicy = accessPolicy
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func updatingAccessPolicy(
    _ policy: ProjectAccessPolicy,
    at date: Date
  ) throws -> ServiceProjectRecord {
    try ServiceProjectRecord(
      id: id,
      name: name,
      root: root,
      accessPolicy: policy,
      createdAt: createdAt,
      updatedAt: date
    )
  }
}

public enum ServiceTaskSource: String, Codable, CaseIterable, Sendable {
  case chatGPT = "chatgpt.mcp"
  case macOSApp = "macos.app"
  case legacyImport = "legacy.import"
}

public enum ServicePermissionMode: String, Codable, CaseIterable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
}

public enum ServiceAccessMode: String, Codable, CaseIterable, Sendable {
  case requestApproval = "request-approval"
  case autoReview = "auto-review"
  case fullAccess = "full-access"
}

public enum ServiceTaskStatus: String, Codable, CaseIterable, Sendable {
  case awaitingLocalApproval = "awaiting_local_approval"
  case starting
  case running
  case waitingForCodexApproval = "waiting_for_codex_approval"
  case completed
  case failed
  case interrupted
  case unknown

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .interrupted:
      true
    case .awaitingLocalApproval, .starting, .running, .waitingForCodexApproval, .unknown:
      false
    }
  }

  var holdsWriteSlot: Bool {
    switch self {
    case .awaitingLocalApproval, .starting, .running, .waitingForCodexApproval, .unknown:
      true
    case .completed, .failed, .interrupted:
      false
    }
  }

  var requiresUnknownRecovery: Bool {
    switch self {
    case .starting, .running, .waitingForCodexApproval:
      true
    case .awaitingLocalApproval, .completed, .failed, .interrupted, .unknown:
      false
    }
  }
}

public enum ServiceSupervisorStatus: String, Codable, CaseIterable, Sendable {
  case disabled
  case starting
  case running
  case degraded
  case completed
}

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

public struct ServiceTaskState: Codable, Equatable, Sendable {
  public let codexThreadID: String?
  public let codexTurnID: String?
  public let status: ServiceTaskStatus
  public let supervisorStatus: ServiceSupervisorStatus
  public let currentStep: String?
  public let changedFiles: [String]
  public let resultSummary: String?
  public let supervisorSummary: String?
  public let failureCode: String?

  public init(
    codexThreadID: String? = nil,
    codexTurnID: String? = nil,
    status: ServiceTaskStatus,
    supervisorStatus: ServiceSupervisorStatus = .disabled,
    currentStep: String? = nil,
    changedFiles: [String] = [],
    resultSummary: String? = nil,
    supervisorSummary: String? = nil,
    failureCode: String? = nil
  ) throws {
    if let codexThreadID {
      try ServiceValidation.identifier(
        codexThreadID,
        field: "task.codexThreadID",
        maximumBytes: 1_024
      )
    }
    if let codexTurnID {
      try ServiceValidation.identifier(
        codexTurnID,
        field: "task.codexTurnID",
        maximumBytes: 1_024
      )
      guard codexThreadID != nil else {
        throw ServiceStoreError.invalidArgument("task.codexBinding")
      }
    }
    try ServiceValidation.optionalText(
      currentStep,
      field: "task.currentStep",
      maximumBytes: 4_096
    )
    try ServiceValidation.uniqueRelativePaths(changedFiles, field: "task.changedFiles")
    try ServiceValidation.optionalText(
      resultSummary,
      field: "task.resultSummary",
      maximumBytes: 32 * 1_024
    )
    try ServiceValidation.optionalText(
      supervisorSummary,
      field: "task.supervisorSummary",
      maximumBytes: 16 * 1_024
    )
    if let failureCode {
      try ServiceValidation.identifier(
        failureCode,
        field: "task.failureCode",
        maximumBytes: 128
      )
    }
    self.codexThreadID = codexThreadID
    self.codexTurnID = codexTurnID
    self.status = status
    self.supervisorStatus = supervisorStatus
    self.currentStep = currentStep
    self.changedFiles = changedFiles
    self.resultSummary = resultSummary
    self.supervisorSummary = supervisorSummary
    self.failureCode = failureCode
  }
}

public struct ServiceTaskRecord: Codable, Equatable, Sendable {
  public let id: TaskID
  public let projectID: ProjectID
  public let source: ServiceTaskSource
  public let clientRequestID: String?
  public let prompt: String
  public let requestedThreadID: String?
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: ServicePermissionMode
  public let networkAllowed: Bool
  public let accessMode: ServiceAccessMode
  public let fastMode: Bool
  public let state: ServiceTaskState
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: TaskID,
    projectID: ProjectID,
    source: ServiceTaskSource,
    clientRequestID: String? = nil,
    prompt: String,
    requestedThreadID: String? = nil,
    executionModel: String,
    executionEffort: String,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: ServicePermissionMode,
    networkAllowed: Bool,
    accessMode: ServiceAccessMode = .requestApproval,
    fastMode: Bool = false,
    state: ServiceTaskState,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.identifier(id.rawValue, field: "task.id", maximumBytes: 128)
    try ServiceValidation.identifier(projectID.rawValue, field: "task.projectID", maximumBytes: 128)
    if let clientRequestID {
      try ServiceValidation.identifier(
        clientRequestID,
        field: "task.clientRequestID",
        maximumBytes: 512
      )
    }
    try ServiceValidation.text(prompt, field: "task.prompt", maximumBytes: 32 * 1_024)
    if let requestedThreadID {
      try ServiceValidation.identifier(
        requestedThreadID,
        field: "task.requestedThreadID",
        maximumBytes: 1_024
      )
    }
    try ServiceValidation.identifier(
      executionModel,
      field: "task.executionModel",
      maximumBytes: 256
    )
    try ServiceValidation.identifier(
      executionEffort,
      field: "task.executionEffort",
      maximumBytes: 64
    )
    guard (supervisorModel == nil) == (supervisorEffort == nil) else {
      throw ServiceStoreError.invalidArgument("task.supervisorSelection")
    }
    if let supervisorModel, let supervisorEffort {
      try ServiceValidation.identifier(
        supervisorModel,
        field: "task.supervisorModel",
        maximumBytes: 256
      )
      try ServiceValidation.identifier(
        supervisorEffort,
        field: "task.supervisorEffort",
        maximumBytes: 64
      )
    }
    guard supervisorModel != nil || state.supervisorStatus == .disabled else {
      throw ServiceStoreError.invalidArgument("task.supervisorStatus")
    }
    try ServiceValidation.date(createdAt, field: "task.createdAt")
    try ServiceValidation.date(updatedAt, field: "task.updatedAt")
    guard updatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("task.updatedAt")
    }
    self.id = id
    self.projectID = projectID
    self.source = source
    self.clientRequestID = clientRequestID
    self.prompt = prompt
    self.requestedThreadID = requestedThreadID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
    self.accessMode = accessMode
    self.fastMode = fastMode
    self.state = state
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func replacingState(
    _ state: ServiceTaskState,
    updatedAt: Date
  ) throws -> ServiceTaskRecord {
    try ServiceTaskRecord(
      id: id,
      projectID: projectID,
      source: source,
      clientRequestID: clientRequestID,
      prompt: prompt,
      requestedThreadID: requestedThreadID,
      executionModel: executionModel,
      executionEffort: executionEffort,
      supervisorModel: supervisorModel,
      supervisorEffort: supervisorEffort,
      permissionMode: permissionMode,
      networkAllowed: networkAllowed,
      accessMode: accessMode,
      fastMode: fastMode,
      state: state,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  func hasSameSubmission(as other: ServiceTaskRecord) -> Bool {
    projectID == other.projectID
      && source == other.source
      && clientRequestID == other.clientRequestID
      && prompt == other.prompt
      && requestedThreadID == other.requestedThreadID
      && executionModel == other.executionModel
      && executionEffort == other.executionEffort
      && supervisorModel == other.supervisorModel
      && supervisorEffort == other.supervisorEffort
      && permissionMode == other.permissionMode
      && networkAllowed == other.networkAllowed
  }

  func hasSameImmutableFields(as other: ServiceTaskRecord) -> Bool {
    id == other.id && createdAt == other.createdAt && hasSameSubmission(as: other)
  }
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

  public init(
    key: String,
    role: ServiceTaskMessageRole,
    content: String,
    createdAt: Date,
    kind: ServiceTaskMessageKind = .agent,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil
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
    self.key = key
    self.role = role
    self.kind = kind
    self.content = content
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
    self.createdAt = createdAt
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
    toolArguments: String? = nil
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

public struct ServiceTaskCreationResult: Equatable, Sendable {
  public let task: ServiceTaskRecord
  public let reusedExistingTask: Bool

  public init(task: ServiceTaskRecord, reusedExistingTask: Bool) {
    self.task = task
    self.reusedExistingTask = reusedExistingTask
  }
}

public struct ServiceTaskRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let source: ServiceTaskSource
  public let clientRequestID: String?
  public let prompt: String
  public let requestedThreadID: String?
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: ServicePermissionMode
  public let networkAllowed: Bool
  public let accessMode: ServiceAccessMode
  public let fastMode: Bool

  public init(
    projectID: ProjectID,
    source: ServiceTaskSource,
    clientRequestID: String? = nil,
    prompt: String,
    requestedThreadID: String? = nil,
    executionModel: String,
    executionEffort: String,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: ServicePermissionMode,
    networkAllowed: Bool = false,
    accessMode: ServiceAccessMode = .requestApproval,
    fastMode: Bool = false
  ) {
    self.projectID = projectID
    self.source = source
    self.clientRequestID = clientRequestID
    self.prompt = prompt
    self.requestedThreadID = requestedThreadID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
    self.accessMode = accessMode
    self.fastMode = fastMode
  }
}
