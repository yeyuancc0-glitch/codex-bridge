import BridgeDomain
import Crypto
import Foundation

public enum TaskRetentionTerminalPhase: String, Codable, CaseIterable, Sendable {
  case completed
  case failed
  case interrupted
  case rejected
}

public enum TaskRetentionHistoryState: String, Codable, CaseIterable, Sendable {
  case full
  case archiveAuthoritative = "archive_authoritative"
  case payloadsPruned = "payloads_pruned"
}

public struct TaskRetentionPolicy: Codable, Equatable, Sendable {
  public static let defaultEventDays = 30
  public static let defaultMetadataDays = 90
  public static let maximumDays = 3_650
  public static let maximumRecentTaskLimit = 10_000

  public let eventDays: Int
  public let metadataDays: Int
  public let recentTaskLimit: Int?
  public let revision: Int64
  public let updatedAt: Date

  public init(
    eventDays: Int = Self.defaultEventDays,
    metadataDays: Int = Self.defaultMetadataDays,
    recentTaskLimit: Int? = nil,
    revision: Int64,
    updatedAt: Date
  ) throws {
    guard (1...Self.maximumDays).contains(eventDays),
      (eventDays...Self.maximumDays).contains(metadataDays),
      recentTaskLimit.map({ (1...Self.maximumRecentTaskLimit).contains($0) }) ?? true,
      revision > 0, updatedAt.timeIntervalSince1970.isFinite
    else { throw EventStoreError.invalidArgument("retentionPolicy") }
    self.eventDays = eventDays
    self.metadataDays = metadataDays
    self.recentTaskLimit = recentTaskLimit
    self.revision = revision
    self.updatedAt = updatedAt
  }
}

public struct TaskRetainedMetadata: Codable, Equatable, Sendable {
  public static let maximumProjectionBytes = 256 * 1_024

  public let taskID: TaskID
  public let terminalPhase: TaskRetentionTerminalPhase
  public let createdAt: Date
  public let startedAt: Date?
  public let completedAt: Date
  public let lastEventSequence: Int64
  public let projectionSchemaVersion: UInt16
  public let projectionPayload: Data
  public let projectionSHA256: Data
  public let historyState: TaskRetentionHistoryState
  public let payloadsPrunedAt: Date?
  public let indexedAt: Date

  public init(
    taskID: TaskID,
    terminalPhase: TaskRetentionTerminalPhase,
    createdAt: Date,
    startedAt: Date?,
    completedAt: Date,
    lastEventSequence: Int64,
    projectionSchemaVersion: UInt16,
    projectionPayload: Data,
    historyState: TaskRetentionHistoryState = .full,
    payloadsPrunedAt: Date? = nil,
    indexedAt: Date = Date()
  ) throws {
    guard Self.validIdentifier(taskID.rawValue), lastEventSequence > 0,
      projectionSchemaVersion > 0,
      !projectionPayload.isEmpty,
      projectionPayload.count <= Self.maximumProjectionBytes,
      Self.validDate(createdAt), Self.validDate(completedAt), Self.validDate(indexedAt),
      createdAt <= completedAt,
      startedAt.map({ Self.validDate($0) && $0 >= createdAt && $0 <= completedAt }) ?? true,
      payloadsPrunedAt.map(Self.validDate) ?? true,
      historyState == .payloadsPruned || payloadsPrunedAt == nil
    else { throw EventStoreError.invalidArgument("retainedMetadata") }
    if historyState == .payloadsPruned, payloadsPrunedAt == nil {
      throw EventStoreError.invalidArgument("retainedMetadata.payloadsPrunedAt")
    }
    self.taskID = taskID
    self.terminalPhase = terminalPhase
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.lastEventSequence = lastEventSequence
    self.projectionSchemaVersion = projectionSchemaVersion
    self.projectionPayload = projectionPayload
    projectionSHA256 = Data(SHA256.hash(data: projectionPayload))
    self.historyState = historyState
    self.payloadsPrunedAt = payloadsPrunedAt
    self.indexedAt = indexedAt
  }

  static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  static func validDate(_ value: Date) -> Bool {
    value.timeIntervalSince1970.isFinite
  }
}

public enum TaskRetentionTargetTier: String, Codable, CaseIterable, Sendable {
  case payloads
  case all
}

public struct TaskRetentionCandidateCursor: Codable, Equatable, Sendable {
  public let completedAt: Date
  public let taskID: TaskID

  public init(completedAt: Date, taskID: TaskID) throws {
    guard TaskRetainedMetadata.validDate(completedAt),
      TaskRetainedMetadata.validIdentifier(taskID.rawValue)
    else { throw EventStoreError.invalidArgument("retentionCandidateCursor") }
    self.completedAt = completedAt
    self.taskID = taskID
  }
}

public struct TaskRetentionCandidate: Equatable, Sendable {
  public let metadata: TaskRetainedMetadata
  public let targetTier: TaskRetentionTargetTier
  public let policyRevision: Int64

  public init(
    metadata: TaskRetainedMetadata,
    targetTier: TaskRetentionTargetTier,
    policyRevision: Int64
  ) throws {
    guard policyRevision > 0 else {
      throw EventStoreError.invalidArgument("retentionCandidate.policyRevision")
    }
    self.metadata = metadata
    self.targetTier = targetTier
    self.policyRevision = policyRevision
  }
}

public struct TaskRetentionTimeline: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let createdAt: Date
  public let startedAt: Date?
  public let lastEventAt: Date
  public let lastEventSequence: Int64

  public init(
    taskID: TaskID,
    createdAt: Date,
    startedAt: Date?,
    lastEventAt: Date,
    lastEventSequence: Int64
  ) throws {
    guard TaskRetainedMetadata.validIdentifier(taskID.rawValue),
      TaskRetainedMetadata.validDate(createdAt),
      startedAt.map(TaskRetainedMetadata.validDate) ?? true,
      TaskRetainedMetadata.validDate(lastEventAt),
      createdAt <= lastEventAt,
      startedAt.map({ $0 >= createdAt && $0 <= lastEventAt }) ?? true,
      lastEventSequence > 0
    else { throw EventStoreError.invalidArgument("retentionTimeline") }
    self.taskID = taskID
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.lastEventAt = lastEventAt
    self.lastEventSequence = lastEventSequence
  }
}

public enum TaskRetentionJobState: String, Codable, CaseIterable, Sendable {
  case prepared
  case pipelinePruning = "pipeline_pruning"
  case pipelinePruned = "pipeline_pruned"
  case supervisionPruning = "supervision_pruning"
  case supervisionPruned = "supervision_pruned"
  case archiveAuthoritative = "archive_authoritative"
  case eventHistoryPruning = "event_history_pruning"
  case eventHistoryPruned = "event_history_pruned"
  case externalPayloadsPruning = "external_payloads_pruning"
  case payloadsComplete = "payloads_complete"
  case metadataPruning = "metadata_pruning"
  case metadataPruned = "metadata_pruned"
  case complete
}

public struct TaskRetentionJob: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let targetTier: TaskRetentionTargetTier
  public let expectedLastEventSequence: Int64
  public let expectedProjectionSHA256: Data
  public let policyRevision: Int64
  public let state: TaskRetentionJobState
  public let eventCursor: Int64
  public let pipelineCursor: Int64
  public let supervisionCursor: Int64
  public let attemptCount: Int
  public let leaseOwner: String?
  public let leaseUntil: Date
  public let nextAttemptAt: Date
  public let lastErrorCode: String?
  public let plannedAt: Date
  public let updatedAt: Date

  public var isSettled: Bool { state == .complete }
}

public struct TaskRetentionStatus: Codable, Equatable, Sendable {
  public let pendingJobCount: Int
  public let leasedJobCount: Int
  public let retryScheduledJobCount: Int
  public let completedJobCount: Int

  public init(
    pendingJobCount: Int,
    leasedJobCount: Int,
    retryScheduledJobCount: Int,
    completedJobCount: Int
  ) {
    self.pendingJobCount = pendingJobCount
    self.leasedJobCount = leasedJobCount
    self.retryScheduledJobCount = retryScheduledJobCount
    self.completedJobCount = completedJobCount
  }
}
