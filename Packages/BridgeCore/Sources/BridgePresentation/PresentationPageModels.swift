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
  public let commands: [String]
  public let changedFiles: [String]
  public let diffSummary: String?
  public let supervisionSummary: String?
  public let verificationSummary: String?
  public let verificationCommands: [String]
  public let canAuthorizeVerification: Bool
  public let diagnosticSummary: String?
  public let canOpenInCodex: Bool
  public let canInterrupt: Bool

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
    commands: [String] = [],
    changedFiles: [String] = [],
    diffSummary: String? = nil,
    supervisionSummary: String? = nil,
    verificationSummary: String? = nil,
    verificationCommands: [String] = [],
    canAuthorizeVerification: Bool = false,
    diagnosticSummary: String? = nil,
    canOpenInCodex: Bool = true,
    canInterrupt: Bool = true
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
    self.commands = commands
    self.changedFiles = changedFiles
    self.diffSummary = diffSummary
    self.supervisionSummary = supervisionSummary
    self.verificationSummary = verificationSummary
    self.verificationCommands = verificationCommands
    self.canAuthorizeVerification = canAuthorizeVerification
    self.diagnosticSummary = diagnosticSummary
    self.canOpenInCodex = canOpenInCodex
    self.canInterrupt = canInterrupt
  }
}

public struct TaskPagePresentation: Equatable, Sendable {
  public let tasks: [TaskRowPresentation]
  public let details: [TaskDetailPresentation]

  public init(tasks: [TaskRowPresentation], details: [TaskDetailPresentation]) {
    self.tasks = tasks
    self.details = details
  }
}

extension TaskDetailPresentation {
  var canRequestInterrupt: Bool {
    canInterrupt && (status == .running || status == .waiting || status == .checking)
  }
}
