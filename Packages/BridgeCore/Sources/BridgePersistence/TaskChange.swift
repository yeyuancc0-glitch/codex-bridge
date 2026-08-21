import BridgeDomain
import Foundation

public struct TaskChange: Equatable, Sendable {
  public let changeID: Int64
  public let taskID: TaskID
  public let eventSequence: Int64
  public let kind: String
  public let createdAt: Date

  public init(
    changeID: Int64,
    taskID: TaskID,
    eventSequence: Int64,
    kind: String,
    createdAt: Date
  ) {
    self.changeID = changeID
    self.taskID = taskID
    self.eventSequence = eventSequence
    self.kind = kind
    self.createdAt = createdAt
  }
}
