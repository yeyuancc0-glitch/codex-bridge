import BridgeDomain
import Foundation

public struct TaskNotificationCandidate: Equatable, Sendable {
  public let stableKey: String
  public let changeID: Int64
  public let taskID: TaskID
  public let eventSequence: Int64
  public let kind: String

  public init(
    stableKey: String,
    changeID: Int64,
    taskID: TaskID,
    eventSequence: Int64,
    kind: String
  ) {
    self.stableKey = stableKey
    self.changeID = changeID
    self.taskID = taskID
    self.eventSequence = eventSequence
    self.kind = kind
  }

  public init(stableKey: String, change: TaskChange) {
    self.init(
      stableKey: stableKey,
      changeID: change.changeID,
      taskID: change.taskID,
      eventSequence: change.eventSequence,
      kind: change.kind
    )
  }
}

public enum TaskNotificationState: String, Equatable, Sendable {
  case reserved
  case scheduled
}

public struct TaskNotificationReservation: Equatable, Sendable {
  public let consumerID: String
  public let stableKey: String
  public let changeID: Int64
  public let taskID: TaskID
  public let eventSequence: Int64
  public let kind: String
  public let state: TaskNotificationState
  public let ownerInstanceID: String
  public let leaseUntil: Date
  public let reservedAt: Date
  public let scheduledAt: Date?

  public init(
    consumerID: String,
    stableKey: String,
    changeID: Int64,
    taskID: TaskID,
    eventSequence: Int64,
    kind: String,
    state: TaskNotificationState,
    ownerInstanceID: String,
    leaseUntil: Date,
    reservedAt: Date,
    scheduledAt: Date?
  ) {
    self.consumerID = consumerID
    self.stableKey = stableKey
    self.changeID = changeID
    self.taskID = taskID
    self.eventSequence = eventSequence
    self.kind = kind
    self.state = state
    self.ownerInstanceID = ownerInstanceID
    self.leaseUntil = leaseUntil
    self.reservedAt = reservedAt
    self.scheduledAt = scheduledAt
  }
}

public struct TaskNotificationPruneResult: Equatable, Sendable {
  public let scheduledReservationsDeleted: Int
  public let changesDeleted: Int

  public var totalDeleted: Int {
    scheduledReservationsDeleted + changesDeleted
  }

  public init(scheduledReservationsDeleted: Int, changesDeleted: Int) {
    self.scheduledReservationsDeleted = scheduledReservationsDeleted
    self.changesDeleted = changesDeleted
  }
}
