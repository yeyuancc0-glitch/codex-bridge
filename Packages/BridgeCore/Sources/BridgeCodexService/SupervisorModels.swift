import BridgeCodexRPC
import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

public struct SupervisorManagerConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let scratchRootURL: URL
  public let requestTimeoutNanoseconds: UInt64
  public let reviewTimeoutNanoseconds: UInt64
  public let eventBufferLimit: Int
  public let outputBufferLimit: Int
  public let maximumConcurrentSessions: Int
  public let maximumQueuedObservations: Int
  public let maximumAutomaticSteers: Int

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    scratchRootURL: URL,
    requestTimeoutNanoseconds: UInt64 = 60_000_000_000,
    reviewTimeoutNanoseconds: UInt64 = 90_000_000_000,
    eventBufferLimit: Int = 128,
    outputBufferLimit: Int = 64,
    maximumConcurrentSessions: Int = 4,
    maximumQueuedObservations: Int = 32,
    maximumAutomaticSteers: Int = 3
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.scratchRootURL = scratchRootURL
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.reviewTimeoutNanoseconds = max(1, reviewTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.outputBufferLimit = max(1, outputBufferLimit)
    self.maximumConcurrentSessions = max(1, maximumConcurrentSessions)
    self.maximumQueuedObservations = max(1, maximumQueuedObservations)
    self.maximumAutomaticSteers = max(0, maximumAutomaticSteers)
  }
}

public enum SupervisorServiceError: Error, Equatable, LocalizedError, Sendable {
  case invalidRequest(String)
  case activeSession(TaskID)
  case sessionLimitReached
  case sessionUnavailable(TaskID)
  case scratchUnavailable
  case modelUnavailable(String)
  case effortUnavailable(String)
  case threadUnavailable
  case turnUnavailable
  case reviewTimedOut
  case approvalRequested
  case invalidDecision
  case processUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let field):
      "The Supervisor request is invalid: \(field)."
    case .activeSession:
      "The task already has a Supervisor session."
    case .sessionLimitReached:
      "The Supervisor session limit was reached."
    case .sessionUnavailable:
      "The Supervisor session is unavailable."
    case .scratchUnavailable:
      "The Supervisor scratch directory is unavailable."
    case .modelUnavailable(let model):
      "The selected Supervisor model is unavailable: \(model)."
    case .effortUnavailable(let effort):
      "The selected Supervisor effort is unavailable: \(effort)."
    case .threadUnavailable:
      "The Supervisor Thread is unavailable."
    case .turnUnavailable:
      "The Supervisor review Turn is unavailable."
    case .reviewTimedOut:
      "The Supervisor review timed out."
    case .approvalRequested:
      "The read-only Supervisor requested an approval."
    case .invalidDecision:
      "The Supervisor returned an invalid structured decision."
    case .processUnavailable:
      "The Supervisor app-server process is unavailable."
    }
  }
}

public enum SupervisorObservationKind: String, Codable, Equatable, Sendable {
  case progress
  case final
}

public struct SupervisorObservation: Codable, Equatable, Sendable {
  public let kind: SupervisorObservationKind
  public let taskID: TaskID
  public let goal: String
  public let currentStep: String?
  public let summary: String
  public let changedFiles: [String]
  public let resultSummary: String?

  public init(
    kind: SupervisorObservationKind,
    taskID: TaskID,
    goal: String,
    currentStep: String? = nil,
    summary: String,
    changedFiles: [String] = [],
    resultSummary: String? = nil
  ) throws {
    try ExecutionValidation.text(goal, field: "supervisor.goal", maximumBytes: 32 * 1_024)
    try ExecutionValidation.optionalText(
      currentStep,
      field: "supervisor.currentStep",
      maximumBytes: 4 * 1_024
    )
    try ExecutionValidation.text(
      summary,
      field: "supervisor.summary",
      maximumBytes: 8 * 1_024
    )
    try ExecutionValidation.relativePaths(changedFiles, field: "supervisor.changedFiles")
    try ExecutionValidation.optionalText(
      resultSummary,
      field: "supervisor.resultSummary",
      maximumBytes: 32 * 1_024
    )
    self.kind = kind
    self.taskID = taskID
    self.goal = goal
    self.currentStep = currentStep
    self.summary = summary
    self.changedFiles = changedFiles
    self.resultSummary = resultSummary
  }
}

public enum SupervisorEvent: Equatable, Sendable {
  case started
  case decision(SupervisorDecision)
  case steer(instruction: String, summary: String)
  case attention(summary: String)
  case completed(summary: String)
  case degraded(code: String, summary: String)
}

public struct SupervisorHandle: Sendable {
  public let taskID: TaskID
  public let events: AsyncStream<SupervisorEvent>

  public init(taskID: TaskID, events: AsyncStream<SupervisorEvent>) {
    self.taskID = taskID
    self.events = events
  }
}
