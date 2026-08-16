import BridgeDomain
import BridgeSupervisor
import Foundation

public enum DurableSupervisionLedgerError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case limitExceeded(field: String, maximum: Int)
  case databaseUnavailable
  case corruptSchema
  case corruptRecord
  case unknownMigration(String)
  case unsupportedSchemaVersion(Int64)
  case scopeConflict(TaskID)
  case checkpointConflict(sequence: UInt64)
  case reviewConflict(SupervisorReviewPosition)
  case actionConflict(String)
  case actionNotFound(String)
  case invalidActionTransition(
    from: DurableSupervisorActionState,
    to: DurableSupervisorActionState
  )
  case pendingActions
  case retentionBlocked(TaskID)
}

public enum DurableSupervisionRetentionRemoval: Equatable, Sendable {
  case removed(Int)
  case alreadyAbsent
}

public protocol DurableSupervisionRetentionStore: Sendable {
  func discardForRetention(taskID: TaskID) async throws
    -> DurableSupervisionRetentionRemoval
}

public struct DurableSupervisionScope: Codable, Equatable, Hashable, Sendable {
  public let taskID: TaskID
  public let projectID: ProjectID
  public let threadID: ThreadID
  public let turnID: TurnID
  public let generation: Int64

  public init(
    taskID: TaskID,
    projectID: ProjectID,
    threadID: ThreadID,
    turnID: TurnID,
    generation: Int64
  ) throws {
    try Self.validate(taskID.rawValue, field: "taskID", maximum: 256)
    try Self.validate(projectID.rawValue, field: "projectID", maximum: 256)
    try Self.validate(threadID.rawValue, field: "threadID", maximum: 1_024)
    try Self.validate(turnID.rawValue, field: "turnID", maximum: 1_024)
    guard generation > 0 else {
      throw DurableSupervisionLedgerError.invalidArgument("generation")
    }
    self.taskID = taskID
    self.projectID = projectID
    self.threadID = threadID
    self.turnID = turnID
    self.generation = generation
  }

  private static func validate(_ value: String, field: String, maximum: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw DurableSupervisionLedgerError.invalidArgument(field) }
  }
}

public enum DurableSupervisionScopeStatus: String, Codable, Equatable, Sendable {
  case active
  case completed
  case superseded

  var isTerminal: Bool { self != .active }
}

public struct DurableSupervisionStateRecord: Codable, Equatable, Sendable {
  public let scope: DurableSupervisionScope
  public let status: DurableSupervisionScopeStatus
  public let configuration: SupervisorGuardConfiguration
  public let state: SupervisorGuardState
  public let stateDigest: String
  public let createdAt: Date
  public let updatedAt: Date
}

public struct DurableSupervisorCheckpointRecord: Codable, Equatable, Sendable {
  public let scope: DurableSupervisionScope
  public let checkpoint: SupervisorCheckpoint
  public let checkpointDigest: String
  public let createdAt: Date
}

public enum DurableSupervisorReviewResult: Codable, Equatable, Sendable {
  case decision(SupervisorDecision)
  case invalidJSON
  case modelFailure(SupervisorModelFailure)
}

public enum DurableSupervisorActionKind: String, Codable, Equatable, Sendable {
  case steer
  case suspend
  case interrupt
}

public enum DurableSupervisorActionState: String, Codable, Equatable, Sendable {
  case pending
  case applied
  case superseded
  case ambiguous
}

public struct DurableSupervisorActionRecord: Codable, Equatable, Sendable {
  public let id: String
  public let scope: DurableSupervisionScope
  public let position: SupervisorReviewPosition
  /// Task event sequence observed by the review that created this action.
  public let taskEventSequence: Int64
  public let kind: DurableSupervisorActionKind
  public let instruction: String
  public let state: DurableSupervisorActionState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct DurableSupervisionReviewRecord: Codable, Equatable, Sendable {
  public let scope: DurableSupervisionScope
  public let position: SupervisorReviewPosition
  public let result: DurableSupervisorReviewResult
  public let state: SupervisorGuardState
  public let stateDigest: String
  public let action: DurableSupervisorActionRecord?
  public let createdAt: Date
}

public struct DurableSupervisionEvidenceSummary: Codable, Equatable, Sendable {
  public let scope: DurableSupervisionScope
  public let checkpointCount: Int
  public let reviewCount: Int
  public let appliedSteerCount: Int
  public let latestDecision: SupervisorDecisionKind?
  public let latestDecisionDigest: String?
  public let reducerStateDigest: String
}
