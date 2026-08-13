import Foundation

public struct ApprovalRowPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let source: String
  public let summary: String
  public let risk: PresentationStatus
  public let requestedAt: Date

  public init(
    id: String,
    source: String,
    summary: String,
    risk: PresentationStatus,
    requestedAt: Date
  ) {
    self.id = id
    self.source = source
    self.summary = summary
    self.risk = risk
    self.requestedAt = requestedAt
  }
}

public struct ApprovalPagePresentation: Equatable, Sendable {
  public let pending: [ApprovalRowPresentation]
  public let resolved: [ApprovalRowPresentation]
  public let details: [CodexApprovalPresentation]

  public init(
    pending: [ApprovalRowPresentation],
    resolved: [ApprovalRowPresentation] = [],
    details: [CodexApprovalPresentation] = []
  ) {
    self.pending = pending
    self.resolved = resolved
    self.details = details
  }
}

public struct ConnectionPagePresentation: Equatable, Sendable {
  public let mode: String
  public let endpoint: String
  public let nodes: [ConnectionNodePresentation]
  public let receivingPaused: Bool
  public let lastError: String?
  public let canChangeReceiving: Bool
  public let canTest: Bool

  public init(
    mode: String,
    endpoint: String,
    nodes: [ConnectionNodePresentation],
    receivingPaused: Bool,
    lastError: String? = nil,
    canChangeReceiving: Bool = true,
    canTest: Bool = true
  ) {
    self.mode = mode
    self.endpoint = endpoint
    self.nodes = nodes
    self.receivingPaused = receivingPaused
    self.lastError = lastError
    self.canChangeReceiving = canChangeReceiving
    self.canTest = canTest
  }
}

public struct LogEntryPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let timestamp: Date
  public let source: String
  public let severity: PresentationStatus
  public let message: String

  public init(
    id: String,
    timestamp: Date,
    source: String,
    severity: PresentationStatus,
    message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.source = source
    self.severity = severity
    self.message = message
  }
}

public struct LogPagePresentation: Equatable, Sendable {
  public let entries: [LogEntryPresentation]
  public let isStreaming: Bool
  public let canExport: Bool

  public init(
    entries: [LogEntryPresentation],
    isStreaming: Bool,
    canExport: Bool = true
  ) {
    self.entries = entries
    self.isStreaming = isStreaming
    self.canExport = canExport
  }
}

public struct SettingTogglePresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let isOn: Bool
  public let isEnabled: Bool

  public init(id: String, title: String, detail: String, isOn: Bool, isEnabled: Bool = true) {
    self.id = id
    self.title = title
    self.detail = detail
    self.isOn = isOn
    self.isEnabled = isEnabled
  }
}

public struct SettingsPagePresentation: Equatable, Sendable {
  public let general: [SettingTogglePresentation]
  public let notifications: [SettingTogglePresentation]
  public let security: [SettingTogglePresentation]
  public let retentionSummary: String

  public init(
    general: [SettingTogglePresentation],
    notifications: [SettingTogglePresentation],
    security: [SettingTogglePresentation],
    retentionSummary: String
  ) {
    self.general = general
    self.notifications = notifications
    self.security = security
    self.retentionSummary = retentionSummary
  }
}

public struct TaskConfirmationPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let goal: String
  public let acceptanceCriteria: [String]
  public let projectName: String
  public let threadDescription: String
  public var executionModel: String
  public var effort: String
  public let permissionMode: String
  public let networkAllowed: Bool
  public let supervisorModel: String
  public let estimatedReadScope: [String]
  public let riskMessages: [String]
  public let availableModels: [String]
  public let availableEfforts: [String]
  public let canRunReadOnly: Bool

  public init(
    id: String,
    goal: String,
    acceptanceCriteria: [String],
    projectName: String,
    threadDescription: String,
    executionModel: String,
    effort: String,
    permissionMode: String,
    networkAllowed: Bool,
    supervisorModel: String,
    estimatedReadScope: [String],
    riskMessages: [String],
    availableModels: [String],
    availableEfforts: [String],
    canRunReadOnly: Bool = true
  ) {
    self.id = id
    self.goal = goal
    self.acceptanceCriteria = acceptanceCriteria
    self.projectName = projectName
    self.threadDescription = threadDescription
    self.executionModel = executionModel
    self.effort = effort
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
    self.supervisorModel = supervisorModel
    self.estimatedReadScope = estimatedReadScope
    self.riskMessages = riskMessages
    self.availableModels = availableModels
    self.availableEfforts = availableEfforts
    self.canRunReadOnly = canRunReadOnly
  }
}

public struct CodexApprovalPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let taskID: String?
  public let source: String
  public let threadID: String
  public let turnID: String
  public let operationID: String?
  public let operationTitle: String
  public let commandArguments: [String]
  public let evidenceItems: [String]
  public let fileOperation: String?
  public let workingDirectory: String
  public let reason: String
  public let supervisorRisk: String
  public let consequences: [String]
  public let canAllow: Bool

  public init(
    id: String,
    taskID: String? = nil,
    source: String,
    threadID: String,
    turnID: String,
    operationID: String? = nil,
    operationTitle: String,
    commandArguments: [String] = [],
    evidenceItems: [String] = [],
    fileOperation: String? = nil,
    workingDirectory: String,
    reason: String,
    supervisorRisk: String,
    consequences: [String],
    canAllow: Bool
  ) {
    self.id = id
    self.taskID = taskID
    self.source = source
    self.threadID = threadID
    self.turnID = turnID
    self.operationID = operationID
    self.operationTitle = operationTitle
    self.commandArguments = commandArguments
    self.evidenceItems = evidenceItems
    self.fileOperation = fileOperation
    self.workingDirectory = workingDirectory
    self.reason = reason
    self.supervisorRisk = supervisorRisk
    self.consequences = consequences
    let hasOperation =
      !commandArguments.isEmpty || !evidenceItems.isEmpty || !(fileOperation?.isEmpty ?? true)
    self.canAllow = canAllow && hasOperation && !workingDirectory.isEmpty && !consequences.isEmpty
  }
}

public enum PresentedBridgeSheet: Identifiable, Equatable, Sendable {
  case taskConfirmation(TaskConfirmationPresentation)
  case codexApproval(CodexApprovalPresentation)

  public var id: String {
    switch self {
    case .taskConfirmation(let confirmation): "task-confirmation-\(confirmation.id)"
    case .codexApproval(let approval): "codex-approval-\(approval.id)"
    }
  }
}
