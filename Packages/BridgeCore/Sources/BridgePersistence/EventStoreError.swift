import BridgeDomain

public enum EventStoreError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case invalidEventSequence(expected: Int64, actual: Int64)
  case optimisticConcurrencyConflict(
    taskID: TaskID,
    expectedLastSequence: Int64,
    actualLastSequence: Int64
  )
  case idempotencyMismatch(origin: String, key: IdempotencyKey)
  case invalidLockSet
  case lockUnavailable(String)
  case corruptEvent(taskID: TaskID, sequence: Int64)
}
