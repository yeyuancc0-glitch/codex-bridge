import BridgeDomain
import CryptoKit
import Foundation
import GRDB

extension EventStore {
  static let maximumActiveRetentionJobs = 256
  static let maximumCompletedRetentionJobs = 256
  static let maximumRetentionClaimLimit = 25
  public static let maximumRetentionQueryLimit = 100
  static let maximumRetentionLeaseDuration: TimeInterval = 3_600

  static func validateTerminalMetadata(
    _ metadata: TaskRetainedMetadata,
    taskID: TaskID,
    expectedLastSequence: Int64,
    terminalEventDate: Date
  ) throws {
    guard metadata.taskID == taskID,
      metadata.historyState == .full,
      metadata.payloadsPrunedAt == nil,
      metadata.lastEventSequence == expectedLastSequence,
      metadata.completedAt == terminalEventDate
    else { throw EventStoreError.invalidArgument("terminalMetadata") }
  }

  public func taskRetentionPolicy() throws -> TaskRetentionPolicy {
    try database.read { db in try Self.fetchRetentionPolicy(in: db) }
  }

  @discardableResult
  public func updateTaskRetentionPolicy(
    eventDays: Int,
    metadataDays: Int,
    recentTaskLimit: Int?,
    expectedRevision: Int64,
    updatedAt: Date = Date()
  ) throws -> TaskRetentionPolicy {
    guard expectedRevision > 0, expectedRevision < Int64.max else {
      throw EventStoreError.invalidArgument("expectedRevision")
    }
    _ = try TaskRetentionPolicy(
      eventDays: eventDays,
      metadataDays: metadataDays,
      recentTaskLimit: recentTaskLimit,
      revision: expectedRevision + 1,
      updatedAt: updatedAt
    )
    return try database.write { db in
      let current = try Self.fetchRetentionPolicy(in: db)
      guard current.revision == expectedRevision else {
        throw EventStoreError.retentionPolicyConflict(
          expected: expectedRevision,
          actual: current.revision
        )
      }
      try db.execute(
        sql: """
          UPDATE task_retention_policy
          SET revision = ?, event_days = ?, metadata_days = ?,
              recent_task_limit = ?, updated_at = ?
          WHERE singleton_id = 1 AND revision = ?
          """,
        arguments: [
          expectedRevision + 1, eventDays, metadataDays, recentTaskLimit,
          updatedAt.timeIntervalSince1970, expectedRevision,
        ]
      )
      guard db.changesCount == 1 else {
        let actual = try Self.fetchRetentionPolicy(in: db).revision
        throw EventStoreError.retentionPolicyConflict(
          expected: expectedRevision,
          actual: actual
        )
      }
      return try Self.fetchRetentionPolicy(in: db)
    }
  }

  public func taskIDsMissingRetainedMetadata(
    afterTaskID: TaskID? = nil,
    limit: Int
  ) throws -> [TaskID] {
    guard (1...Self.maximumRetentionQueryLimit).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT tasks.task_id
          FROM tasks
          LEFT JOIN task_retained_metadata retained
            ON retained.task_id = tasks.task_id
          WHERE tasks.task_id > ? AND retained.task_id IS NULL
          ORDER BY tasks.task_id
          LIMIT ?
          """,
        arguments: [afterTaskID?.rawValue ?? "", limit]
      ).map(TaskID.init(rawValue:))
    }
  }

  public func taskRetentionTimeline(for taskID: TaskID) throws -> TaskRetentionTimeline? {
    guard TaskRetainedMetadata.validIdentifier(taskID.rawValue) else {
      throw EventStoreError.invalidArgument("taskID")
    }
    return try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT tasks.created_at,
                   tasks.last_event_seq,
                   last_event.created_at AS last_event_at,
                   (
                     SELECT MIN(started.created_at)
                     FROM task_events started
                     WHERE started.task_id = tasks.task_id
                       AND started.kind = 'task.turnStarted'
                   ) AS started_at
            FROM tasks
            JOIN task_events last_event
              ON last_event.task_id = tasks.task_id
             AND last_event.seq = tasks.last_event_seq
            WHERE tasks.task_id = ? AND tasks.last_event_seq > 0
            """,
          arguments: [taskID.rawValue]
        )
      else { return nil }
      return try TaskRetentionTimeline(
        taskID: taskID,
        createdAt: try Self.date(row["created_at"], field: "timeline.createdAt"),
        startedAt: try Self.optionalDate(row["started_at"], field: "timeline.startedAt"),
        lastEventAt: try Self.date(row["last_event_at"], field: "timeline.lastEventAt"),
        lastEventSequence: row["last_event_seq"]
      )
    }
  }

  @discardableResult
  public func indexTerminalRetainedMetadata(
    _ metadata: TaskRetainedMetadata
  ) throws -> TaskRetainedMetadata {
    guard metadata.historyState == .full, metadata.payloadsPrunedAt == nil else {
      throw EventStoreError.invalidArgument("retainedMetadata.historyState")
    }
    return try database.write { db in
      let actual = try Int64.fetchOne(
        db,
        sql: "SELECT last_event_seq FROM tasks WHERE task_id = ?",
        arguments: [metadata.taskID.rawValue]
      )
      guard actual == metadata.lastEventSequence else {
        throw EventStoreError.optimisticConcurrencyConflict(
          taskID: metadata.taskID,
          expectedLastSequence: metadata.lastEventSequence,
          actualLastSequence: actual ?? 0
        )
      }
      if let existing = try Self.fetchRetainedMetadata(taskID: metadata.taskID, in: db) {
        guard Self.sameImmutableMetadata(existing, metadata) else {
          throw EventStoreError.retainedMetadataConflict(metadata.taskID)
        }
        return existing
      }
      try Self.insert(metadata, in: db)
      return metadata
    }
  }

  public func retainedMetadata(for taskID: TaskID) throws -> TaskRetainedMetadata? {
    guard TaskRetainedMetadata.validIdentifier(taskID.rawValue) else {
      throw EventStoreError.invalidArgument("taskID")
    }
    return try database.read { db in
      try Self.fetchRetainedMetadata(taskID: taskID, in: db)
    }
  }

  @discardableResult
  public func transitionRetainedMetadataHistory(
    taskID: TaskID,
    expectedState: TaskRetentionHistoryState,
    to state: TaskRetentionHistoryState,
    at date: Date = Date()
  ) throws -> TaskRetainedMetadata {
    guard Self.validHistoryTransition(from: expectedState, to: state),
      TaskRetainedMetadata.validDate(date)
    else { throw EventStoreError.invalidArgument("historyState") }
    return try database.write { db in
      guard let current = try Self.fetchRetainedMetadata(taskID: taskID, in: db) else {
        throw EventStoreError.retainedMetadataConflict(taskID)
      }
      guard current.historyState == expectedState else {
        throw EventStoreError.retainedMetadataConflict(taskID)
      }
      try db.execute(
        sql: """
          UPDATE task_retained_metadata
          SET history_state = ?, payloads_pruned_at = ?
          WHERE task_id = ? AND history_state = ?
          """,
        arguments: [
          state.rawValue,
          state == .payloadsPruned ? date.timeIntervalSince1970 : nil,
          taskID.rawValue,
          expectedState.rawValue,
        ]
      )
      guard db.changesCount == 1,
        let updated = try Self.fetchRetainedMetadata(taskID: taskID, in: db)
      else { throw EventStoreError.retainedMetadataConflict(taskID) }
      return updated
    }
  }

  public func retentionCandidates(
    now: Date = Date(),
    after cursor: TaskRetentionCandidateCursor? = nil,
    limit: Int
  ) throws -> [TaskRetentionCandidate] {
    guard TaskRetainedMetadata.validDate(now),
      (1...Self.maximumRetentionQueryLimit).contains(limit)
    else { throw EventStoreError.invalidArgument("retentionCandidates") }
    return try database.read { db in
      let policy = try Self.fetchRetentionPolicy(in: db)
      let eventCutoff = now.addingTimeInterval(-TimeInterval(policy.eventDays) * 86_400)
      let metadataCutoff = now.addingTimeInterval(-TimeInterval(policy.metadataDays) * 86_400)
      let recentBoundary = try Self.recentTaskBoundary(policy: policy, in: db)
      let fullClause = Self.fullRetentionClause(recentBoundary: recentBoundary)
      let allClause = Self.allRetentionClause(recentBoundary: recentBoundary)
      var arguments: StatementArguments = [
        cursor?.completedAt.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude,
        cursor?.completedAt.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude,
        cursor?.taskID.rawValue ?? "",
      ]
      arguments += [eventCutoff.timeIntervalSince1970]
      arguments += Self.boundaryArguments(recentBoundary)
      arguments += [metadataCutoff.timeIntervalSince1970]
      arguments += [metadataCutoff.timeIntervalSince1970]
      arguments += Self.boundaryArguments(recentBoundary)
      arguments += [eventCutoff.timeIntervalSince1970]
      arguments += Self.boundaryArguments(recentBoundary)
      arguments += [now.timeIntervalSince1970, limit]
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT retained.*
          FROM task_retained_metadata retained
          LEFT JOIN task_retention_jobs job ON job.task_id = retained.task_id
          WHERE (
            retained.completed_at > ?
            OR (retained.completed_at = ? AND retained.task_id > ?)
          )
            AND (
              \(fullClause)
              OR (
                retained.history_state != 'payloads_pruned'
                AND retained.completed_at <= ?
              )
            )
            AND (
              retained.history_state != 'payloads_pruned'
              OR \(allClause)
            )
            AND (
              job.task_id IS NULL
              OR (\(fullClause) AND job.target_tier = 'payloads')
            )
            AND NOT EXISTS (
              SELECT 1 FROM locks WHERE locks.owner_task_id = retained.task_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM task_notification_ledger notifications
              WHERE notifications.task_id = retained.task_id
                AND notifications.state = 'reserved'
                AND notifications.lease_until > ?
            )
            AND (
              retained.history_state != 'full'
              OR EXISTS (
                SELECT 1 FROM task_state_snapshots snapshot
                WHERE snapshot.task_id = retained.task_id
                  AND snapshot.last_event_seq = retained.last_event_seq
                  AND snapshot.recovery_required = 0
              )
            )
          ORDER BY retained.completed_at, retained.task_id
          LIMIT ?
          """,
        arguments: arguments
      )
      return try rows.map { row in
        let metadata = try Self.decodeRetainedMetadata(row)
        let target = Self.targetTier(
          metadata: metadata,
          metadataCutoff: metadataCutoff,
          recentBoundary: recentBoundary
        )
        return try TaskRetentionCandidate(
          metadata: metadata,
          targetTier: target,
          policyRevision: policy.revision
        )
      }
    }
  }

  @discardableResult
  public func planRetentionJob(
    for candidate: TaskRetentionCandidate,
    at date: Date = Date()
  ) throws -> TaskRetentionJob {
    guard TaskRetainedMetadata.validDate(date) else {
      throw EventStoreError.invalidArgument("date")
    }
    return try database.write { db in
      try Self.trimCompletedRetentionJobs(in: db)
      let policy = try Self.fetchRetentionPolicy(in: db)
      guard policy.revision == candidate.policyRevision else {
        throw EventStoreError.retentionPolicyConflict(
          expected: candidate.policyRevision,
          actual: policy.revision
        )
      }
      guard
        let stored = try Self.fetchRetainedMetadata(
          taskID: candidate.metadata.taskID,
          in: db
        ),
        Self.sameImmutableMetadata(stored, candidate.metadata),
        try Self.isRetentionSafe(metadata: stored, now: date, in: db)
      else { throw EventStoreError.retainedMetadataConflict(candidate.metadata.taskID) }
      if let existing = try Self.fetchRetentionJob(taskID: stored.taskID, in: db) {
        return try Self.upgrade(
          existing,
          target: candidate.targetTier,
          policyRevision: policy.revision,
          at: date,
          in: db
        )
      }
      let activeCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM task_retention_jobs WHERE state != 'complete'"
        ) ?? 0
      guard activeCount < Self.maximumActiveRetentionJobs else {
        throw EventStoreError.retentionJobCapacityExceeded
      }
      let initialState: TaskRetentionJobState =
        stored.historyState == .payloadsPruned ? .payloadsComplete : .prepared
      try db.execute(
        sql: """
          INSERT INTO task_retention_jobs (
            task_id, target_tier, expected_last_event_seq,
            expected_projection_sha256, policy_revision, state,
            planned_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          stored.taskID.rawValue, candidate.targetTier.rawValue,
          stored.lastEventSequence, stored.projectionSHA256,
          policy.revision, initialState.rawValue,
          date.timeIntervalSince1970, date.timeIntervalSince1970,
        ]
      )
      guard let job = try Self.fetchRetentionJob(taskID: stored.taskID, in: db) else {
        throw EventStoreError.retentionJobConflict(stored.taskID)
      }
      return job
    }
  }

  public func retentionJob(for taskID: TaskID) throws -> TaskRetentionJob? {
    try database.read { db in try Self.fetchRetentionJob(taskID: taskID, in: db) }
  }

  public func claimRetentionJobs(
    ownerInstanceID: String,
    now: Date = Date(),
    leaseUntil: Date,
    limit: Int
  ) throws -> [TaskRetentionJob] {
    try Self.validateLeaseOwner(ownerInstanceID)
    try Self.validateRetentionLease(now: now, leaseUntil: leaseUntil)
    guard (1...Self.maximumRetentionClaimLimit).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try database.write { db in
      let taskIDs = try String.fetchAll(
        db,
        sql: """
          SELECT task_id FROM task_retention_jobs
          WHERE state != 'complete'
            AND next_attempt_at <= ?
            AND (lease_owner = ? OR lease_until <= ?)
          ORDER BY updated_at, task_id
          LIMIT ?
          """,
        arguments: [now.timeIntervalSince1970, ownerInstanceID, now.timeIntervalSince1970, limit]
      )
      var claimed: [TaskRetentionJob] = []
      for taskID in taskIDs {
        try db.execute(
          sql: """
            UPDATE task_retention_jobs
            SET lease_owner = ?, lease_until = ?, updated_at = ?
            WHERE task_id = ? AND state != 'complete'
              AND (lease_owner = ? OR lease_until <= ?)
            """,
          arguments: [
            ownerInstanceID, leaseUntil.timeIntervalSince1970, now.timeIntervalSince1970,
            taskID, ownerInstanceID, now.timeIntervalSince1970,
          ]
        )
        if db.changesCount == 1,
          let job = try Self.fetchRetentionJob(taskID: TaskID(rawValue: taskID), in: db)
        {
          claimed.append(job)
        }
      }
      return claimed
    }
  }

  @discardableResult
  public func advanceRetentionJob(
    taskID: TaskID,
    ownerInstanceID: String,
    expectedState: TaskRetentionJobState,
    to state: TaskRetentionJobState,
    at date: Date = Date()
  ) throws -> TaskRetentionJob {
    try Self.validateLeaseOwner(ownerInstanceID)
    guard TaskRetainedMetadata.validDate(date) else {
      throw EventStoreError.invalidArgument("date")
    }
    return try database.write { db in
      guard let current = try Self.fetchRetentionJob(taskID: taskID, in: db),
        current.state == expectedState,
        current.leaseOwner == ownerInstanceID,
        current.leaseUntil > date,
        Self.validJobTransition(from: expectedState, to: state, target: current.targetTier)
      else { throw EventStoreError.retentionLeaseUnavailable(taskID) }
      let completes = state == .complete
      try db.execute(
        sql: """
          UPDATE task_retention_jobs
          SET state = ?, lease_owner = ?, lease_until = ?, updated_at = ?
          WHERE task_id = ? AND state = ? AND lease_owner = ? AND lease_until > ?
          """,
        arguments: [
          state.rawValue, completes ? nil : ownerInstanceID,
          completes ? 0 : current.leaseUntil.timeIntervalSince1970,
          date.timeIntervalSince1970, taskID.rawValue, expectedState.rawValue,
          ownerInstanceID, date.timeIntervalSince1970,
        ]
      )
      guard db.changesCount == 1 else {
        throw EventStoreError.retentionLeaseUnavailable(taskID)
      }
      if completes {
        try Self.trimCompletedRetentionJobs(in: db)
      }
      guard let updated = try Self.fetchRetentionJob(taskID: taskID, in: db) else {
        throw EventStoreError.retentionJobConflict(taskID)
      }
      return updated
    }
  }

  @discardableResult
  public func updateRetentionJobProgress(
    taskID: TaskID,
    ownerInstanceID: String,
    expectedState: TaskRetentionJobState,
    eventCursor: Int64,
    pipelineCursor: Int64,
    supervisionCursor: Int64,
    at date: Date = Date()
  ) throws -> TaskRetentionJob {
    try Self.validateLeaseOwner(ownerInstanceID)
    guard eventCursor >= 0, pipelineCursor >= 0, supervisionCursor >= 0,
      TaskRetainedMetadata.validDate(date)
    else { throw EventStoreError.invalidArgument("retentionProgress") }
    return try database.write { db in
      guard let current = try Self.fetchRetentionJob(taskID: taskID, in: db),
        current.state == expectedState,
        current.leaseOwner == ownerInstanceID,
        current.leaseUntil > date,
        eventCursor >= current.eventCursor,
        pipelineCursor >= current.pipelineCursor,
        supervisionCursor >= current.supervisionCursor
      else { throw EventStoreError.retentionLeaseUnavailable(taskID) }
      try db.execute(
        sql: """
          UPDATE task_retention_jobs
          SET event_cursor = ?, pipeline_cursor = ?, supervision_cursor = ?, updated_at = ?
          WHERE task_id = ? AND state = ? AND lease_owner = ? AND lease_until > ?
          """,
        arguments: [
          eventCursor, pipelineCursor, supervisionCursor, date.timeIntervalSince1970,
          taskID.rawValue, expectedState.rawValue, ownerInstanceID,
          date.timeIntervalSince1970,
        ]
      )
      guard db.changesCount == 1,
        let updated = try Self.fetchRetentionJob(taskID: taskID, in: db)
      else { throw EventStoreError.retentionLeaseUnavailable(taskID) }
      return updated
    }
  }

  public func releaseRetentionJob(
    taskID: TaskID,
    ownerInstanceID: String,
    errorCode: String? = nil,
    retryAt: Date,
    at date: Date = Date()
  ) throws {
    try Self.validateLeaseOwner(ownerInstanceID)
    if let errorCode { try Self.validateErrorCode(errorCode) }
    guard TaskRetainedMetadata.validDate(date), TaskRetainedMetadata.validDate(retryAt),
      retryAt >= date
    else { throw EventStoreError.invalidArgument("retryAt") }
    try database.write { db in
      guard let current = try Self.fetchRetentionJob(taskID: taskID, in: db),
        current.leaseOwner == ownerInstanceID
      else { throw EventStoreError.retentionLeaseUnavailable(taskID) }
      let increment = errorCode == nil ? 0 : 1
      try db.execute(
        sql: """
          UPDATE task_retention_jobs
          SET lease_owner = NULL, lease_until = 0,
              attempt_count = attempt_count + ?, next_attempt_at = ?,
              last_error_code = ?, updated_at = ?
          WHERE task_id = ? AND lease_owner = ?
          """,
        arguments: [
          increment, retryAt.timeIntervalSince1970, errorCode,
          date.timeIntervalSince1970, taskID.rawValue, ownerInstanceID,
        ]
      )
      guard db.changesCount == 1 else {
        throw EventStoreError.retentionLeaseUnavailable(taskID)
      }
    }
  }

  public func taskRetentionStatus(now: Date = Date()) throws -> TaskRetentionStatus {
    guard TaskRetainedMetadata.validDate(now) else {
      throw EventStoreError.invalidArgument("now")
    }
    return try database.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            SUM(CASE WHEN state != 'complete' THEN 1 ELSE 0 END) AS pending,
            SUM(CASE WHEN state != 'complete' AND lease_until > ? THEN 1 ELSE 0 END) AS leased,
            SUM(CASE WHEN state != 'complete' AND next_attempt_at > ? THEN 1 ELSE 0 END) AS retrying,
            SUM(CASE WHEN state = 'complete' THEN 1 ELSE 0 END) AS completed
          FROM task_retention_jobs
          """,
        arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]
      )
      return TaskRetentionStatus(
        pendingJobCount: row?["pending"] ?? 0,
        leasedJobCount: row?["leased"] ?? 0,
        retryScheduledJobCount: row?["retrying"] ?? 0,
        completedJobCount: row?["completed"] ?? 0
      )
    }
  }

  @discardableResult
  public func pruneCompletedRetentionJobs(limit: Int = 100) throws -> Int {
    guard (1...Self.maximumRetentionQueryLimit).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try database.write { db in
      try db.execute(
        sql: """
          DELETE FROM task_retention_jobs
          WHERE task_id IN (
            SELECT task_id FROM task_retention_jobs
            WHERE state = 'complete'
            ORDER BY updated_at, task_id
            LIMIT ?
          )
          """,
        arguments: [limit]
      )
      return db.changesCount
    }
  }

  @discardableResult
  public func pruneTaskEventHistory(
    taskID: TaskID,
    expectedLastEventSequence: Int64,
    expectedProjectionSHA256: Data,
    at date: Date = Date()
  ) throws -> Int {
    guard expectedLastEventSequence > 0, expectedProjectionSHA256.count == 32,
      TaskRetainedMetadata.validDate(date)
    else { throw EventStoreError.invalidArgument("eventHistoryRetention") }
    return try database.write { db in
      guard let metadata = try Self.fetchRetainedMetadata(taskID: taskID, in: db),
        metadata.lastEventSequence == expectedLastEventSequence,
        metadata.projectionSHA256 == expectedProjectionSHA256,
        metadata.historyState == .archiveAuthoritative
      else { throw EventStoreError.retentionMetadataNotReady(taskID) }
      let activeLease =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM task_notification_ledger
              WHERE task_id = ? AND state = 'reserved' AND lease_until > ?
            )
            """,
          arguments: [taskID.rawValue, date.timeIntervalSince1970]
        ) ?? false
      guard !activeLease else { throw EventStoreError.retentionSafetyBlocked(taskID) }
      let eventCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM task_events WHERE task_id = ?",
          arguments: [taskID.rawValue]
        ) ?? 0
      try db.execute(
        sql: "DELETE FROM task_notification_ledger WHERE task_id = ? AND state = 'scheduled'",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_change_log WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_events WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      return eventCount
    }
  }

  @discardableResult
  public func purgeTaskMetadata(
    taskID: TaskID,
    expectedLastEventSequence: Int64,
    expectedProjectionSHA256: Data,
    at date: Date = Date()
  ) throws -> Bool {
    guard expectedLastEventSequence > 0, expectedProjectionSHA256.count == 32,
      TaskRetainedMetadata.validDate(date)
    else { throw EventStoreError.invalidArgument("metadataRetention") }
    return try database.write { db in
      guard let metadata = try Self.fetchRetainedMetadata(taskID: taskID, in: db) else {
        return false
      }
      guard metadata.lastEventSequence == expectedLastEventSequence,
        metadata.projectionSHA256 == expectedProjectionSHA256,
        metadata.historyState == .payloadsPruned
      else { throw EventStoreError.retentionMetadataNotReady(taskID) }
      let hasLocks =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS (SELECT 1 FROM locks WHERE owner_task_id = ?)",
          arguments: [taskID.rawValue]
        ) ?? false
      guard !hasLocks else { throw EventStoreError.retentionSafetyBlocked(taskID) }
      let activeLease =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM task_notification_ledger
              WHERE task_id = ? AND state = 'reserved' AND lease_until > ?
            )
            """,
          arguments: [taskID.rawValue, date.timeIntervalSince1970]
        ) ?? false
      guard !activeLease else { throw EventStoreError.retentionSafetyBlocked(taskID) }
      try db.execute(
        sql: "DELETE FROM task_notification_ledger WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_change_log WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_events WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM submission_claims WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_state_snapshots WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM task_retained_metadata WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM tasks WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      guard db.changesCount == 1 else { throw EventStoreError.retentionMetadataNotReady(taskID) }
      return true
    }
  }
}

extension EventStore {
  private struct RetentionBoundary {
    let completedAt: Date
    let taskID: String
  }

  private static func fetchRetentionPolicy(in db: Database) throws -> TaskRetentionPolicy {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT revision, event_days, metadata_days, recent_task_limit, updated_at
          FROM task_retention_policy WHERE singleton_id = 1
          """
      )
    else { throw EventStoreError.invalidArgument("retentionPolicy") }
    return try TaskRetentionPolicy(
      eventDays: row["event_days"],
      metadataDays: row["metadata_days"],
      recentTaskLimit: row["recent_task_limit"],
      revision: row["revision"],
      updatedAt: try date(row["updated_at"], field: "policy.updatedAt")
    )
  }

  private static func trimCompletedRetentionJobs(in db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM task_retention_jobs
        WHERE state = 'complete'
          AND task_id NOT IN (
            SELECT task_id FROM task_retention_jobs
            WHERE state = 'complete'
            ORDER BY updated_at DESC, task_id DESC
            LIMIT ?
          )
        """,
      arguments: [maximumCompletedRetentionJobs]
    )
  }

  static func insert(_ metadata: TaskRetainedMetadata, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO task_retained_metadata (
          task_id, terminal_phase, created_at, started_at, completed_at,
          last_event_seq, projection_schema_version, projection_payload,
          projection_sha256, history_state, payloads_pruned_at, indexed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        metadata.taskID.rawValue, metadata.terminalPhase.rawValue,
        metadata.createdAt.timeIntervalSince1970,
        metadata.startedAt?.timeIntervalSince1970,
        metadata.completedAt.timeIntervalSince1970, metadata.lastEventSequence,
        Int(metadata.projectionSchemaVersion), metadata.projectionPayload,
        metadata.projectionSHA256, metadata.historyState.rawValue,
        metadata.payloadsPrunedAt?.timeIntervalSince1970,
        metadata.indexedAt.timeIntervalSince1970,
      ]
    )
  }

  static func fetchRetainedMetadata(
    taskID: TaskID,
    in db: Database
  ) throws -> TaskRetainedMetadata? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM task_retained_metadata WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    else { return nil }
    return try decodeRetainedMetadata(row)
  }

  private static func decodeRetainedMetadata(_ row: Row) throws -> TaskRetainedMetadata {
    let taskID = TaskID(rawValue: row["task_id"])
    guard let phase = TaskRetentionTerminalPhase(rawValue: row["terminal_phase"]),
      let history = TaskRetentionHistoryState(rawValue: row["history_state"]),
      let schemaVersion = UInt16(exactly: row["projection_schema_version"] as Int64)
    else { throw EventStoreError.retainedMetadataConflict(taskID) }
    let payload: Data = row["projection_payload"]
    let digest: Data = row["projection_sha256"]
    let metadata = try TaskRetainedMetadata(
      taskID: taskID,
      terminalPhase: phase,
      createdAt: try date(row["created_at"], field: "metadata.createdAt"),
      startedAt: try optionalDate(row["started_at"], field: "metadata.startedAt"),
      completedAt: try date(row["completed_at"], field: "metadata.completedAt"),
      lastEventSequence: row["last_event_seq"],
      projectionSchemaVersion: schemaVersion,
      projectionPayload: payload,
      historyState: history,
      payloadsPrunedAt: try optionalDate(
        row["payloads_pruned_at"],
        field: "metadata.payloadsPrunedAt"
      ),
      indexedAt: try date(row["indexed_at"], field: "metadata.indexedAt")
    )
    guard metadata.projectionSHA256 == digest else {
      throw EventStoreError.retainedMetadataConflict(taskID)
    }
    return metadata
  }

  static func sameImmutableMetadata(
    _ lhs: TaskRetainedMetadata,
    _ rhs: TaskRetainedMetadata
  ) -> Bool {
    lhs.taskID == rhs.taskID && lhs.terminalPhase == rhs.terminalPhase
      && lhs.createdAt == rhs.createdAt && lhs.startedAt == rhs.startedAt
      && lhs.completedAt == rhs.completedAt
      && lhs.lastEventSequence == rhs.lastEventSequence
      && lhs.projectionSchemaVersion == rhs.projectionSchemaVersion
      && lhs.projectionPayload == rhs.projectionPayload
      && lhs.projectionSHA256 == rhs.projectionSHA256
  }

  private static func validHistoryTransition(
    from: TaskRetentionHistoryState,
    to: TaskRetentionHistoryState
  ) -> Bool {
    switch (from, to) {
    case (.full, .archiveAuthoritative), (.archiveAuthoritative, .payloadsPruned): true
    default: false
    }
  }

  private static func recentTaskBoundary(
    policy: TaskRetentionPolicy,
    in db: Database
  ) throws -> RetentionBoundary? {
    guard let limit = policy.recentTaskLimit else { return nil }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT completed_at, task_id FROM task_retained_metadata
          ORDER BY completed_at DESC, task_id DESC
          LIMIT 1 OFFSET ?
          """,
        arguments: [limit - 1]
      )
    else { return nil }
    return RetentionBoundary(
      completedAt: try date(row["completed_at"], field: "boundary.completedAt"),
      taskID: row["task_id"]
    )
  }

  private static func fullRetentionClause(recentBoundary: RetentionBoundary?) -> String {
    guard recentBoundary != nil else { return "retained.completed_at <= ?" }
    return """
      (
        retained.completed_at <= ?
        OR retained.completed_at < ?
        OR (retained.completed_at = ? AND retained.task_id < ?)
      )
      """
  }

  private static func allRetentionClause(recentBoundary: RetentionBoundary?) -> String {
    guard recentBoundary != nil else { return "retained.completed_at <= ?" }
    return """
      (
        retained.completed_at <= ?
        OR retained.completed_at < ?
        OR (retained.completed_at = ? AND retained.task_id < ?)
      )
      """
  }

  private static func boundaryArguments(
    _ boundary: RetentionBoundary?
  ) -> StatementArguments {
    guard let boundary else { return [] }
    return [
      boundary.completedAt.timeIntervalSince1970,
      boundary.completedAt.timeIntervalSince1970,
      boundary.taskID,
    ]
  }

  private static func targetTier(
    metadata: TaskRetainedMetadata,
    metadataCutoff: Date,
    recentBoundary: RetentionBoundary?
  ) -> TaskRetentionTargetTier {
    if metadata.completedAt <= metadataCutoff { return .all }
    guard let recentBoundary else { return .payloads }
    if metadata.completedAt < recentBoundary.completedAt { return .all }
    if metadata.completedAt == recentBoundary.completedAt,
      metadata.taskID.rawValue < recentBoundary.taskID
    {
      return .all
    }
    return .payloads
  }

  private static func isRetentionSafe(
    metadata: TaskRetainedMetadata,
    now: Date,
    in db: Database
  ) throws -> Bool {
    let lockCount =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM locks WHERE owner_task_id = ?",
        arguments: [metadata.taskID.rawValue]
      ) ?? 0
    guard lockCount == 0 else { return false }
    let activeNotificationLease =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM task_notification_ledger
            WHERE task_id = ? AND state = 'reserved' AND lease_until > ?
          )
          """,
        arguments: [metadata.taskID.rawValue, now.timeIntervalSince1970]
      ) ?? false
    guard !activeNotificationLease else { return false }
    if metadata.historyState != .full { return true }
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM task_state_snapshots
          WHERE task_id = ? AND last_event_seq = ? AND recovery_required = 0
        )
        """,
      arguments: [metadata.taskID.rawValue, metadata.lastEventSequence]
    ) ?? false
  }

  private static func upgrade(
    _ job: TaskRetentionJob,
    target: TaskRetentionTargetTier,
    policyRevision: Int64,
    at date: Date,
    in db: Database
  ) throws -> TaskRetentionJob {
    guard job.targetTier == .payloads, target == .all else {
      if job.targetTier == target || job.targetTier == .all { return job }
      throw EventStoreError.retentionJobConflict(job.taskID)
    }
    let state: TaskRetentionJobState = job.state == .complete ? .payloadsComplete : job.state
    try db.execute(
      sql: """
        UPDATE task_retention_jobs
        SET target_tier = 'all', policy_revision = ?, state = ?,
            lease_owner = NULL, lease_until = 0, next_attempt_at = 0,
            last_error_code = NULL, updated_at = ?
        WHERE task_id = ? AND target_tier = 'payloads'
        """,
      arguments: [
        policyRevision, state.rawValue, date.timeIntervalSince1970, job.taskID.rawValue,
      ]
    )
    guard db.changesCount == 1,
      let updated = try fetchRetentionJob(taskID: job.taskID, in: db)
    else { throw EventStoreError.retentionJobConflict(job.taskID) }
    return updated
  }

  private static func fetchRetentionJob(
    taskID: TaskID,
    in db: Database
  ) throws -> TaskRetentionJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM task_retention_jobs WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    else { return nil }
    return try decodeRetentionJob(row)
  }

  private static func decodeRetentionJob(_ row: Row) throws -> TaskRetentionJob {
    let taskID = TaskID(rawValue: row["task_id"])
    guard TaskRetainedMetadata.validIdentifier(taskID.rawValue),
      let target = TaskRetentionTargetTier(rawValue: row["target_tier"]),
      let state = TaskRetentionJobState(rawValue: row["state"])
    else { throw EventStoreError.retentionJobConflict(taskID) }
    let digest: Data = row["expected_projection_sha256"]
    let lastSequence: Int64 = row["expected_last_event_seq"]
    let policyRevision: Int64 = row["policy_revision"]
    let eventCursor: Int64 = row["event_cursor"]
    let pipelineCursor: Int64 = row["pipeline_cursor"]
    let supervisionCursor: Int64 = row["supervision_cursor"]
    let attemptCount: Int = row["attempt_count"]
    let leaseOwner: String? = row["lease_owner"]
    let lastErrorCode: String? = row["last_error_code"]
    guard digest.count == 32, lastSequence > 0, policyRevision > 0,
      eventCursor >= 0, pipelineCursor >= 0, supervisionCursor >= 0,
      attemptCount >= 0,
      leaseOwner.map(validLeaseOwner) ?? true,
      lastErrorCode.map(validErrorCode) ?? true
    else { throw EventStoreError.retentionJobConflict(taskID) }
    return TaskRetentionJob(
      taskID: taskID,
      targetTier: target,
      expectedLastEventSequence: lastSequence,
      expectedProjectionSHA256: digest,
      policyRevision: policyRevision,
      state: state,
      eventCursor: eventCursor,
      pipelineCursor: pipelineCursor,
      supervisionCursor: supervisionCursor,
      attemptCount: attemptCount,
      leaseOwner: leaseOwner,
      leaseUntil: try date(row["lease_until"], field: "job.leaseUntil"),
      nextAttemptAt: try date(row["next_attempt_at"], field: "job.nextAttemptAt"),
      lastErrorCode: lastErrorCode,
      plannedAt: try date(row["planned_at"], field: "job.plannedAt"),
      updatedAt: try date(row["updated_at"], field: "job.updatedAt")
    )
  }

  private static func validJobTransition(
    from: TaskRetentionJobState,
    to: TaskRetentionJobState,
    target: TaskRetentionTargetTier
  ) -> Bool {
    switch (from, to) {
    case (.prepared, .pipelinePruning),
      (.pipelinePruning, .pipelinePruned),
      (.pipelinePruned, .supervisionPruning),
      (.supervisionPruning, .supervisionPruned),
      (.supervisionPruned, .archiveAuthoritative),
      (.archiveAuthoritative, .externalPayloadsPruning),
      (.archiveAuthoritative, .eventHistoryPruning),
      (.eventHistoryPruning, .eventHistoryPruned),
      (.eventHistoryPruned, .externalPayloadsPruning),
      (.externalPayloadsPruning, .payloadsComplete),
      (.metadataPruning, .metadataPruned),
      (.metadataPruned, .complete):
      true
    case (.payloadsComplete, .complete):
      target == .payloads
    case (.payloadsComplete, .metadataPruning):
      target == .all
    default:
      false
    }
  }

  private static func validateLeaseOwner(_ value: String) throws {
    guard validLeaseOwner(value) else {
      throw EventStoreError.invalidArgument("ownerInstanceID")
    }
  }

  private static func validLeaseOwner(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func validateErrorCode(_ value: String) throws {
    guard validErrorCode(value) else {
      throw EventStoreError.invalidArgument("errorCode")
    }
  }

  private static func validErrorCode(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 46 || byte == 95
      }
  }

  private static func validateRetentionLease(now: Date, leaseUntil: Date) throws {
    guard TaskRetainedMetadata.validDate(now), TaskRetainedMetadata.validDate(leaseUntil),
      leaseUntil > now,
      leaseUntil.timeIntervalSince(now) <= maximumRetentionLeaseDuration
    else { throw EventStoreError.invalidArgument("leaseUntil") }
  }

  private static func date(_ timestamp: Double, field: String) throws -> Date {
    guard timestamp.isFinite else { throw EventStoreError.invalidArgument(field) }
    return Date(timeIntervalSince1970: timestamp)
  }

  private static func optionalDate(_ timestamp: Double?, field: String) throws -> Date? {
    guard let timestamp else { return nil }
    return try date(timestamp, field: field)
  }
}
