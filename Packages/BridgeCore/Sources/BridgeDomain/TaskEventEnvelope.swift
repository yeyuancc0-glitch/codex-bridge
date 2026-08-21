import Foundation

public struct TaskEventEnvelope: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let sequence: Int64
  public let schemaVersion: UInt16
  public let source: String
  public let kind: String
  public let severity: String
  public let payload: Data
  public let createdAt: Date

  public init(
    taskID: TaskID,
    sequence: Int64,
    schemaVersion: UInt16,
    source: String,
    kind: String,
    severity: String,
    payload: Data,
    createdAt: Date
  ) {
    self.taskID = taskID
    self.sequence = sequence
    self.schemaVersion = schemaVersion
    self.source = source
    self.kind = kind
    self.severity = severity
    self.payload = payload
    self.createdAt = createdAt
  }
}
