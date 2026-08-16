import Foundation

public struct ConnectionNodePresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let status: PresentationStatus
  public let checkedAt: PresentationTimestamp?

  public init(
    id: String,
    title: String,
    detail: String,
    status: PresentationStatus,
    checkedAt: PresentationTimestamp? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.checkedAt = checkedAt
  }
}

public struct AttentionItemPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let status: PresentationStatus
  public let destination: BridgeNavigationDestination

  public init(
    id: String,
    title: String,
    detail: String,
    status: PresentationStatus,
    destination: BridgeNavigationDestination
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.destination = destination
  }
}

public struct OverviewPresentation: Equatable, Sendable {
  public let connectionPath: [ConnectionNodePresentation]
  public let attentionItems: [AttentionItemPresentation]
  public let activeTasks: [TaskRowPresentation]
  public let recentTasks: [TaskRowPresentation]
  public let registeredProjectCount: Int
  public let modelCatalogRefreshedAt: PresentationTimestamp?
  public let rateLimitSummary: String?

  public init(
    connectionPath: [ConnectionNodePresentation],
    attentionItems: [AttentionItemPresentation],
    activeTasks: [TaskRowPresentation],
    recentTasks: [TaskRowPresentation],
    registeredProjectCount: Int,
    modelCatalogRefreshedAt: PresentationTimestamp? = nil,
    rateLimitSummary: String? = nil
  ) {
    self.connectionPath = connectionPath
    self.attentionItems = attentionItems
    self.activeTasks = activeTasks
    self.recentTasks = recentTasks
    self.registeredProjectCount = registeredProjectCount
    self.modelCatalogRefreshedAt = modelCatalogRefreshedAt
    self.rateLimitSummary = rateLimitSummary
  }
}

public struct TaskRowPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let projectName: String
  public let threadLabel: String
  public let status: PresentationStatus
  public let model: String
  public let updatedAt: Date

  public init(
    id: String,
    title: String,
    projectName: String,
    threadLabel: String,
    status: PresentationStatus,
    model: String,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.projectName = projectName
    self.threadLabel = threadLabel
    self.status = status
    self.model = model
    self.updatedAt = updatedAt
  }
}

public struct TaskEvidenceEventPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let source: String
  public let kind: String
  public let detail: String
  public let status: PresentationStatus
  public let occurredAt: Date

  public init(
    id: String,
    source: String,
    kind: String,
    detail: String,
    status: PresentationStatus,
    occurredAt: Date
  ) {
    self.id = id
    self.source = source
    self.kind = kind
    self.detail = detail
    self.status = status
    self.occurredAt = occurredAt
  }
}

public struct SupervisorActionPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let kind: String
  public let instruction: String
  public let taskEventSequence: Int64
  public let createdAt: Date

  public init(
    id: String,
    kind: String,
    instruction: String,
    taskEventSequence: Int64,
    createdAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.instruction = instruction
    self.taskEventSequence = taskEventSequence
    self.createdAt = createdAt
  }
}

public struct TaskDetailPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let goal: String
  public let projectName: String
  public let threadID: String
  public let model: String
  public let effort: String
  public let status: PresentationStatus
  public let supervisorStatus: PresentationStatus
  public let startedAt: Date?
  public let plan: [String]
  public let currentStep: String?
  public let finalSummary: String?
  public let timeline: [TaskEvidenceEventPresentation]
  public let evidenceState: TaskEvidenceLoadPresentation
  public let commands: [String]
  public let changedFiles: [String]
  public let diffSummary: String?
  public let supervisionSummary: String?
  public let ambiguousSupervisorActions: [SupervisorActionPresentation]
  public let verificationSummary: String?
  public let verificationCommands: [String]
  public let canAuthorizeVerification: Bool
  public let diagnosticSummary: String?
  public let canOpenInCodex: Bool
  public let canInterrupt: Bool
  public let recoveryMessage: String?
  public let canSuspendAmbiguousRecovery: Bool

  public init(
    id: String,
    title: String,
    goal: String,
    projectName: String,
    threadID: String,
    model: String,
    effort: String,
    status: PresentationStatus,
    supervisorStatus: PresentationStatus,
    startedAt: Date? = nil,
    plan: [String] = [],
    currentStep: String? = nil,
    finalSummary: String? = nil,
    timeline: [TaskEvidenceEventPresentation] = [],
    evidenceState: TaskEvidenceLoadPresentation = .notLoaded,
    commands: [String] = [],
    changedFiles: [String] = [],
    diffSummary: String? = nil,
    supervisionSummary: String? = nil,
    ambiguousSupervisorActions: [SupervisorActionPresentation] = [],
    verificationSummary: String? = nil,
    verificationCommands: [String] = [],
    canAuthorizeVerification: Bool = false,
    diagnosticSummary: String? = nil,
    canOpenInCodex: Bool = true,
    canInterrupt: Bool = true,
    recoveryMessage: String? = nil,
    canSuspendAmbiguousRecovery: Bool = false
  ) {
    self.id = id
    self.title = title
    self.goal = goal
    self.projectName = projectName
    self.threadID = threadID
    self.model = model
    self.effort = effort
    self.status = status
    self.supervisorStatus = supervisorStatus
    self.startedAt = startedAt
    self.plan = plan
    self.currentStep = currentStep
    self.finalSummary = finalSummary
    self.timeline = timeline
    self.evidenceState = evidenceState
    self.commands = commands
    self.changedFiles = changedFiles
    self.diffSummary = diffSummary
    self.supervisionSummary = supervisionSummary
    self.ambiguousSupervisorActions = ambiguousSupervisorActions
    self.verificationSummary = verificationSummary
    self.verificationCommands = verificationCommands
    self.canAuthorizeVerification = canAuthorizeVerification
    self.diagnosticSummary = diagnosticSummary
    self.canOpenInCodex = canOpenInCodex
    self.canInterrupt = canInterrupt
    self.recoveryMessage = recoveryMessage
    self.canSuspendAmbiguousRecovery = canSuspendAmbiguousRecovery
  }
}

public enum TaskEvidenceLoadPresentation: Equatable, Sendable {
  case notLoaded
  case loading
  case available
  case unavailable(String)
}

public struct TaskPagePresentation: Equatable, Sendable {
  public let tasks: [TaskRowPresentation]
  public let details: [TaskDetailPresentation]
  public let readOnlyComposer: PresentationLoadState<ReadOnlyTaskComposerPresentation>?

  public init(
    tasks: [TaskRowPresentation],
    details: [TaskDetailPresentation],
    readOnlyComposer: PresentationLoadState<ReadOnlyTaskComposerPresentation>? = nil
  ) {
    self.tasks = tasks
    self.details = details
    self.readOnlyComposer = readOnlyComposer
  }
}

public struct LocalTaskProjectOptionPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct LocalTaskModelOptionPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let efforts: [String]
  public let defaultReasoningEffort: String?
  public let isDefault: Bool

  public init(
    id: String,
    displayName: String,
    efforts: [String],
    defaultReasoningEffort: String? = nil,
    isDefault: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.efforts = efforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.isDefault = isDefault
  }

  public init(id: String, displayName: String, efforts: [String], isDefault: Bool) {
    self.init(
      id: id,
      displayName: displayName,
      efforts: efforts,
      defaultReasoningEffort: nil,
      isDefault: isDefault
    )
  }

  public var preferredEffort: String {
    if let defaultReasoningEffort, efforts.contains(defaultReasoningEffort) {
      return defaultReasoningEffort
    }
    return efforts.first ?? ""
  }
}

public struct ReadOnlyTaskComposerPresentation: Equatable, Sendable {
  public let requestID: String
  public let projects: [LocalTaskProjectOptionPresentation]
  public let initialProjectID: String
  public let threadID: String?
  public let executionModels: [LocalTaskModelOptionPresentation]
  public let supervisorModels: [LocalTaskModelOptionPresentation]
  public let supervisorAvailable: Bool
  public let blocker: String?
  public let isSubmitting: Bool

  public init(
    requestID: String,
    projects: [LocalTaskProjectOptionPresentation],
    initialProjectID: String,
    threadID: String? = nil,
    executionModels: [LocalTaskModelOptionPresentation],
    supervisorModels: [LocalTaskModelOptionPresentation],
    supervisorAvailable: Bool = true,
    blocker: String? = nil,
    isSubmitting: Bool = false
  ) {
    self.requestID = requestID
    self.projects = projects
    self.initialProjectID = initialProjectID
    self.threadID = threadID
    self.executionModels = executionModels
    self.supervisorModels = supervisorModels
    self.supervisorAvailable = supervisorAvailable
    self.blocker = blocker
    self.isSubmitting = isSubmitting
  }
}

public struct ReadOnlyTaskDraftPresentation: Equatable, Sendable {
  public let requestID: String
  public let projectID: String
  public let threadID: String?
  public let goal: String
  public let acceptanceCriteria: [String]
  public let executionModel: String
  public let executionEffort: String
  public let supervisorEnabled: Bool
  public let supervisorModel: String
  public let supervisorEffort: String

  public init(
    requestID: String,
    projectID: String,
    threadID: String? = nil,
    goal: String,
    acceptanceCriteria: [String],
    executionModel: String,
    executionEffort: String,
    supervisorEnabled: Bool = true,
    supervisorModel: String,
    supervisorEffort: String
  ) {
    self.requestID = requestID
    self.projectID = projectID
    self.threadID = threadID
    self.goal = goal
    self.acceptanceCriteria = acceptanceCriteria
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorEnabled = supervisorEnabled
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
  }
}

extension TaskDetailPresentation {
  var canRequestInterrupt: Bool {
    canInterrupt && (status == .running || status == .waiting || status == .checking)
  }
}
