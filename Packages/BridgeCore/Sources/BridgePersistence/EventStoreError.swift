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
  case lockOwnershipMismatch(String)
  case corruptEvent(taskID: TaskID, sequence: Int64)
  case notificationCursorConflict(consumerID: String, expected: Int64, actual: Int64)
  case notificationCandidateMismatch(String)
  case notificationLeaseUnavailable(String)
  case notificationNotFound(consumerID: String, stableKey: String)
  case retentionPolicyConflict(expected: Int64, actual: Int64)
  case retainedMetadataConflict(TaskID)
  case retentionJobConflict(TaskID)
  case retentionJobCapacityExceeded
  case retentionLeaseUnavailable(TaskID)
  case retentionSafetyBlocked(TaskID)
  case retentionMetadataNotReady(TaskID)
}
