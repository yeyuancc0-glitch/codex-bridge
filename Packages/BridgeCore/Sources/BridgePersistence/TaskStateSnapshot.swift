import BridgeDomain
import Foundation

public struct TaskStateSnapshot: Equatable, Sendable {
  public let taskID: TaskID
  public let lastEventSequence: Int64
  public let schemaVersion: UInt16
  public let payload: Data
  public let recoveryRequired: Bool

  public init(
    taskID: TaskID,
    lastEventSequence: Int64,
    schemaVersion: UInt16,
    payload: Data,
    recoveryRequired: Bool
  ) {
    self.taskID = taskID
    self.lastEventSequence = lastEventSequence
    self.schemaVersion = schemaVersion
    self.payload = payload
    self.recoveryRequired = recoveryRequired
  }
}
