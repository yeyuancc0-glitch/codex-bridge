import BridgeDomain
import Foundation

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
