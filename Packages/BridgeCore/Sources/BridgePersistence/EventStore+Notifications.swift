import BridgeDomain
import Foundation
import GRDB

extension EventStore {
  @discardableResult
  public func setNotificationsEnabled(
    _ enabled: Bool,
    consumerID: String,
    expectedCursor: Int64,
    updatedAt: Date = Date()
  ) throws -> Int64 {
    try Self.validateConsumerID(consumerID)
    guard expectedCursor >= 0 else { throw EventStoreError.invalidArgument("cursor") }
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("updatedAt")
    }
    return try database.write { db in
      try Self.installConsumerIfMissing(consumerID, at: updatedAt, in: db)
      let current = try Self.consumerCursor(consumerID, in: db)
      guard current == expectedCursor else {
        throw EventStoreError.notificationCursorConflict(
          consumerID: consumerID,
          expected: expectedCursor,
          actual: current
        )
      }
      let head = try Self.taskChangeHead(in: db)
      try db.execute(
        sql: """
          UPDATE task_notification_consumers
          SET change_cursor = ?, updated_at = ?
          WHERE consumer_id = ? AND change_cursor = ?
          """,
        arguments: [head, updatedAt.timeIntervalSince1970, consumerID, expectedCursor]
      )
      guard db.changesCount == 1 else {
        let actual = try Self.consumerCursor(consumerID, in: db)
        throw EventStoreError.notificationCursorConflict(
          consumerID: consumerID,
          expected: expectedCursor,
          actual: actual
        )
      }
      try db.execute(
        sql: """
          UPDATE lifecycle_preferences
          SET notifications_enabled = ?, updated_at = ?
          WHERE singleton_id = 1
          """,
        arguments: [enabled, updatedAt.timeIntervalSince1970]
      )
      guard db.changesCount == 1 else {
        throw EventStoreError.invalidArgument("lifecyclePreferences")
      }
      return head
    }
  }

  public func notificationConsumerCursor(_ consumerID: String) throws -> Int64 {
    try Self.validateConsumerID(consumerID)
    return try database.read { db in
      try Int64.fetchOne(
        db,
        sql: """
          SELECT change_cursor
          FROM task_notification_consumers
          WHERE consumer_id = ?
          """,
        arguments: [consumerID]
      ) ?? 0
    }
  }

  @discardableResult
  public func fastForwardNotificationConsumer(
    consumerID: String,
    expectedCursor: Int64,
    throughChangeID: Int64,
    at updatedAt: Date = Date()
  ) throws -> Int64 {
    try Self.validateConsumerID(consumerID)
    guard expectedCursor >= 0, throughChangeID >= expectedCursor else {
      throw EventStoreError.invalidArgument("cursor")
    }
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("at")
    }
    return try database.write { db in
      let head = try Self.taskChangeHead(in: db)
      guard throughChangeID <= head else {
        throw EventStoreError.invalidArgument("throughChangeID")
      }
      try Self.installConsumerIfMissing(consumerID, at: updatedAt, in: db)
      let current = try Self.consumerCursor(consumerID, in: db)
      guard current == expectedCursor else {
        throw EventStoreError.notificationCursorConflict(
          consumerID: consumerID,
          expected: expectedCursor,
          actual: current
        )
      }
      try db.execute(
        sql: """
          UPDATE task_notification_consumers
          SET change_cursor = ?, updated_at = ?
          WHERE consumer_id = ? AND change_cursor = ?
          """,
        arguments: [throughChangeID, updatedAt.timeIntervalSince1970, consumerID, expectedCursor]
      )
      guard db.changesCount == 1 else {
        let actual = try Self.consumerCursor(consumerID, in: db)
        throw EventStoreError.notificationCursorConflict(
          consumerID: consumerID,
          expected: expectedCursor,
          actual: actual
        )
      }
      return throughChangeID
    }
  }

  public func reserveNotifications(
    consumerID: String,
    ownerInstanceID: String,
    expectedCursor: Int64,
    throughChangeID: Int64,
    candidates: [TaskNotificationCandidate],
    reservedAt: Date = Date(),
    leaseUntil: Date
  ) throws -> [TaskNotificationReservation] {
    try Self.validateReservationRequest(
      consumerID: consumerID,
      ownerInstanceID: ownerInstanceID,
      expectedCursor: expectedCursor,
      throughChangeID: throughChangeID,
      candidates: candidates,
      reservedAt: reservedAt,
      leaseUntil: leaseUntil
    )
    return try database.write { db in
      try Self.installConsumerIfMissing(consumerID, at: reservedAt, in: db)
      try Self.requireCursor(
        consumerID,
        expected: expectedCursor,
        through: throughChangeID,
        in: db
      )
      let orderedCandidates = candidates.sorted { $0.changeID < $1.changeID }
      let reservations = try orderedCandidates.map {
        try Self.reserve(
          $0,
          consumerID: consumerID,
          ownerInstanceID: ownerInstanceID,
          at: reservedAt,
          leaseUntil: leaseUntil,
          in: db
        )
      }
      try db.execute(
        sql: """
          UPDATE task_notification_consumers
          SET change_cursor = ?, updated_at = ?
          WHERE consumer_id = ? AND change_cursor = ?
          """,
        arguments: [
          throughChangeID,
          reservedAt.timeIntervalSince1970,
          consumerID,
          expectedCursor,
        ]
      )
      guard db.changesCount == 1 else {
        let actual = try Self.consumerCursor(consumerID, in: db)
        throw EventStoreError.notificationCursorConflict(
          consumerID: consumerID,
          expected: expectedCursor,
          actual: actual
        )
      }
      return reservations
    }
  }

  public func claimPendingNotificationReservations(
    consumerID: String,
    ownerInstanceID: String,
    now: Date = Date(),
    leaseUntil: Date,
    allowOwnerTakeover: Bool = false,
    limit: Int
  ) throws -> [TaskNotificationReservation] {
    try Self.validateConsumerID(consumerID)
    try Self.validateOwnerInstanceID(ownerInstanceID)
    try Self.validateLease(now: now, leaseUntil: leaseUntil)
    guard (1...500).contains(limit) else { throw EventStoreError.invalidArgument("limit") }
    return try database.write { db in
      let stableKeys = try String.fetchAll(
        db,
        sql: """
          SELECT stable_key
          FROM task_notification_ledger
          WHERE consumer_id = ?
            AND state = 'reserved'
            AND (? = 1 OR owner_instance_id = ? OR lease_until <= ?)
          ORDER BY change_id
          LIMIT ?
          """,
        arguments: [
          consumerID,
          allowOwnerTakeover,
          ownerInstanceID,
          now.timeIntervalSince1970,
          limit,
        ]
      )
      return try stableKeys.compactMap { stableKey in
        try Self.claimPending(
          consumerID: consumerID,
          stableKey: stableKey,
          ownerInstanceID: ownerInstanceID,
          now: now,
          leaseUntil: leaseUntil,
          allowOwnerTakeover: allowOwnerTakeover,
          in: db
        )
      }
    }
  }

  public func notificationReservation(
    consumerID: String,
    stableKey: String
  ) throws -> TaskNotificationReservation? {
    try Self.validateConsumerID(consumerID)
    try Self.validateStableKey(stableKey)
    return try database.read { db in
      try Self.reservation(consumerID: consumerID, stableKey: stableKey, in: db)
    }
  }

  public func markNotificationScheduled(
    consumerID: String,
    stableKey: String,
    ownerInstanceID: String,
    scheduledAt: Date = Date()
  ) throws -> TaskNotificationReservation {
    try Self.validateConsumerID(consumerID)
    try Self.validateStableKey(stableKey)
    try Self.validateOwnerInstanceID(ownerInstanceID)
    guard scheduledAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("scheduledAt")
    }
    return try database.write { db in
      guard
        let existing = try Self.reservation(
          consumerID: consumerID,
          stableKey: stableKey,
          in: db
        )
      else {
        throw EventStoreError.notificationNotFound(
          consumerID: consumerID,
          stableKey: stableKey
        )
      }
      guard existing.ownerInstanceID == ownerInstanceID else {
        throw EventStoreError.notificationLeaseUnavailable(stableKey)
      }
      guard existing.state == .reserved else { return existing }
      guard existing.leaseUntil > scheduledAt else {
        throw EventStoreError.notificationLeaseUnavailable(stableKey)
      }
      try db.execute(
        sql: """
          UPDATE task_notification_ledger
          SET state = 'scheduled', scheduled_at = ?
          WHERE consumer_id = ? AND stable_key = ? AND state = 'reserved'
            AND owner_instance_id = ? AND lease_until > ?
          """,
        arguments: [
          scheduledAt.timeIntervalSince1970,
          consumerID,
          stableKey,
          ownerInstanceID,
          scheduledAt.timeIntervalSince1970,
        ]
      )
      guard db.changesCount == 1 else {
        throw EventStoreError.notificationLeaseUnavailable(stableKey)
      }
      guard
        let updated = try Self.reservation(
          consumerID: consumerID,
          stableKey: stableKey,
          in: db
        )
      else {
        throw EventStoreError.notificationNotFound(
          consumerID: consumerID,
          stableKey: stableKey
        )
      }
      return updated
    }
  }

  public func releaseNotificationReservation(
    consumerID: String,
    stableKey: String,
    ownerInstanceID: String,
    now: Date = Date()
  ) throws {
    try Self.validateConsumerID(consumerID)
    try Self.validateStableKey(stableKey)
    try Self.validateOwnerInstanceID(ownerInstanceID)
    guard now.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("now")
    }
    try database.write { db in
      guard
        let existing = try Self.reservation(
          consumerID: consumerID,
          stableKey: stableKey,
          in: db
        )
      else {
        throw EventStoreError.notificationNotFound(
          consumerID: consumerID,
          stableKey: stableKey
        )
      }
      guard existing.state == .reserved, existing.ownerInstanceID == ownerInstanceID else {
        throw EventStoreError.notificationLeaseUnavailable(stableKey)
      }
      try db.execute(
        sql: """
          UPDATE task_notification_ledger
          SET lease_until = ?
          WHERE consumer_id = ? AND stable_key = ? AND state = 'reserved'
            AND owner_instance_id = ?
          """,
        arguments: [now.timeIntervalSince1970, consumerID, stableKey, ownerInstanceID]
      )
      guard db.changesCount == 1 else {
        throw EventStoreError.notificationLeaseUnavailable(stableKey)
      }
    }
  }

  private static func validateReservationRequest(
    consumerID: String,
    ownerInstanceID: String,
    expectedCursor: Int64,
    throughChangeID: Int64,
    candidates: [TaskNotificationCandidate],
    reservedAt: Date,
    leaseUntil: Date
  ) throws {
    try validateConsumerID(consumerID)
    try validateOwnerInstanceID(ownerInstanceID)
    try validateLease(now: reservedAt, leaseUntil: leaseUntil)
    guard expectedCursor >= 0, throughChangeID >= expectedCursor else {
      throw EventStoreError.invalidArgument("cursor")
    }
    guard candidates.count <= 500, reservedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("candidates")
    }
    let keys = Set(candidates.map(\.stableKey))
    let changeIDs = Set(candidates.map(\.changeID))
    guard keys.count == candidates.count, changeIDs.count == candidates.count else {
      throw EventStoreError.invalidArgument("candidates")
    }
    for candidate in candidates {
      try validateStableKey(candidate.stableKey)
      guard candidate.changeID > expectedCursor, candidate.changeID <= throughChangeID else {
        throw EventStoreError.invalidArgument("candidates")
      }
    }
  }

  private static func installConsumerIfMissing(
    _ consumerID: String,
    at date: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO task_notification_consumers (consumer_id, change_cursor, updated_at)
        VALUES (?, 0, ?)
        ON CONFLICT(consumer_id) DO NOTHING
        """,
      arguments: [consumerID, date.timeIntervalSince1970]
    )
  }

  private static func requireCursor(
    _ consumerID: String,
    expected: Int64,
    through: Int64,
    in db: Database
  ) throws {
    let actual = try consumerCursor(consumerID, in: db)
    guard actual == expected else {
      throw EventStoreError.notificationCursorConflict(
        consumerID: consumerID,
        expected: expected,
        actual: actual
      )
    }
    guard through > expected else { return }
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) AS count, MAX(change_id) AS maximum
        FROM task_change_log
        WHERE change_id > ? AND change_id <= ?
        """,
      arguments: [expected, through]
    )
    let count: Int = row?["count"] ?? 0
    let maximum: Int64? = row?["maximum"]
    guard count > 0, count <= 500, maximum == through else {
      throw EventStoreError.invalidArgument("throughChangeID")
    }
  }

  private static func reserve(
    _ candidate: TaskNotificationCandidate,
    consumerID: String,
    ownerInstanceID: String,
    at date: Date,
    leaseUntil: Date,
    in db: Database
  ) throws -> TaskNotificationReservation {
    let change = try change(candidate.changeID, in: db)
    guard change.taskID == candidate.taskID,
      change.eventSequence == candidate.eventSequence,
      change.kind == candidate.kind
    else { throw EventStoreError.notificationCandidateMismatch(candidate.stableKey) }
    if let existing = try reservationForChange(
      consumerID: consumerID,
      changeID: candidate.changeID,
      in: db
    ) {
      guard existing.stableKey == candidate.stableKey,
        existing.state == .reserved,
        existing.ownerInstanceID == ownerInstanceID || existing.leaseUntil <= date
      else {
        throw EventStoreError.notificationLeaseUnavailable(candidate.stableKey)
      }
      try db.execute(
        sql: """
          UPDATE task_notification_ledger
          SET owner_instance_id = ?, lease_until = ?
          WHERE consumer_id = ? AND stable_key = ? AND state = 'reserved'
            AND (owner_instance_id = ? OR lease_until <= ?)
          """,
        arguments: [
          ownerInstanceID,
          leaseUntil.timeIntervalSince1970,
          consumerID,
          candidate.stableKey,
          ownerInstanceID,
          date.timeIntervalSince1970,
        ]
      )
      guard db.changesCount == 1,
        let claimed = try reservation(
          consumerID: consumerID,
          stableKey: candidate.stableKey,
          in: db
        )
      else {
        throw EventStoreError.notificationCandidateMismatch(candidate.stableKey)
      }
      return claimed
    }
    try db.execute(
      sql: """
        INSERT INTO task_notification_ledger (
            consumer_id, stable_key, change_id, task_id, event_seq, kind,
            state, reserved_at, scheduled_at, owner_instance_id, lease_until
        ) VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?, NULL, ?, ?)
        """,
      arguments: [
        consumerID,
        candidate.stableKey,
        candidate.changeID,
        candidate.taskID.rawValue,
        candidate.eventSequence,
        candidate.kind,
        date.timeIntervalSince1970,
        ownerInstanceID,
        leaseUntil.timeIntervalSince1970,
      ]
    )
    guard
      let stored = try reservation(
        consumerID: consumerID,
        stableKey: candidate.stableKey,
        in: db
      )
    else { throw EventStoreError.notificationCandidateMismatch(candidate.stableKey) }
    return stored
  }

  private static func claimPending(
    consumerID: String,
    stableKey: String,
    ownerInstanceID: String,
    now: Date,
    leaseUntil: Date,
    allowOwnerTakeover: Bool,
    in db: Database
  ) throws -> TaskNotificationReservation? {
    try db.execute(
      sql: """
        UPDATE task_notification_ledger
        SET owner_instance_id = ?, lease_until = ?
        WHERE consumer_id = ? AND stable_key = ? AND state = 'reserved'
          AND (? = 1 OR owner_instance_id = ? OR lease_until <= ?)
        """,
      arguments: [
        ownerInstanceID,
        leaseUntil.timeIntervalSince1970,
        consumerID,
        stableKey,
        allowOwnerTakeover,
        ownerInstanceID,
        now.timeIntervalSince1970,
      ]
    )
    guard db.changesCount == 1 else { return nil }
    return try reservation(consumerID: consumerID, stableKey: stableKey, in: db)
  }

  private static func change(_ changeID: Int64, in db: Database) throws -> TaskChange {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT change_id, task_id, event_seq, kind, created_at
          FROM task_change_log
          WHERE change_id = ?
          """,
        arguments: [changeID]
      )
    else { throw EventStoreError.invalidArgument("candidate.changeID") }
    return try decodeChange(row)
  }

  private static func consumerCursor(_ consumerID: String, in db: Database) throws -> Int64 {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT change_cursor
        FROM task_notification_consumers
        WHERE consumer_id = ?
        """,
      arguments: [consumerID]
    ) ?? 0
  }

  private static func reservation(
    consumerID: String,
    stableKey: String,
    in db: Database
  ) throws -> TaskNotificationReservation? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT consumer_id, stable_key, change_id, task_id, event_seq, kind,
                 state, reserved_at, scheduled_at, owner_instance_id, lease_until
          FROM task_notification_ledger
          WHERE consumer_id = ? AND stable_key = ?
          """,
        arguments: [consumerID, stableKey]
      )
    else { return nil }
    return try decodeReservation(row)
  }

  private static func reservationForChange(
    consumerID: String,
    changeID: Int64,
    in db: Database
  ) throws -> TaskNotificationReservation? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT consumer_id, stable_key, change_id, task_id, event_seq, kind,
                 state, reserved_at, scheduled_at, owner_instance_id, lease_until
          FROM task_notification_ledger
          WHERE consumer_id = ? AND change_id = ?
          """,
        arguments: [consumerID, changeID]
      )
    else { return nil }
    return try decodeReservation(row)
  }

  private static func decodeReservation(_ row: Row) throws -> TaskNotificationReservation {
    let consumerID: String = row["consumer_id"]
    let stableKey: String = row["stable_key"]
    let changeID: Int64 = row["change_id"]
    let taskID = TaskID(rawValue: row["task_id"])
    let eventSequence: Int64 = row["event_seq"]
    let kind: String = row["kind"]
    let stateValue: String = row["state"]
    let ownerInstanceID: String = row["owner_instance_id"]
    let leaseTimestamp: Double = row["lease_until"]
    let reservedTimestamp: Double = row["reserved_at"]
    let scheduledTimestamp: Double? = row["scheduled_at"]
    guard let state = TaskNotificationState(rawValue: stateValue),
      changeID > 0,
      eventSequence > 0,
      leaseTimestamp.isFinite,
      reservedTimestamp.isFinite,
      scheduledTimestamp?.isFinite != false,
      (state == .scheduled) == (scheduledTimestamp != nil),
      validStoredIdentifier(taskID.rawValue, maximumBytes: 1_024),
      validStoredIdentifier(kind, maximumBytes: 1_024)
    else { throw EventStoreError.notificationCandidateMismatch(stableKey) }
    try validateConsumerID(consumerID)
    try validateStableKey(stableKey)
    try validateOwnerInstanceID(ownerInstanceID)
    return TaskNotificationReservation(
      consumerID: consumerID,
      stableKey: stableKey,
      changeID: changeID,
      taskID: taskID,
      eventSequence: eventSequence,
      kind: kind,
      state: state,
      ownerInstanceID: ownerInstanceID,
      leaseUntil: Date(timeIntervalSince1970: leaseTimestamp),
      reservedAt: Date(timeIntervalSince1970: reservedTimestamp),
      scheduledAt: scheduledTimestamp.map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func validateConsumerID(_ value: String) throws {
    guard validLedgerKey(value, maximumBytes: 128) else {
      throw EventStoreError.invalidArgument("consumerID")
    }
  }

  private static func validateStableKey(_ value: String) throws {
    guard validLedgerKey(value, maximumBytes: 512) else {
      throw EventStoreError.invalidArgument("stableKey")
    }
  }

  private static func validateOwnerInstanceID(_ value: String) throws {
    guard validLedgerKey(value, maximumBytes: 128) else {
      throw EventStoreError.invalidArgument("ownerInstanceID")
    }
  }

  private static func validateLease(now: Date, leaseUntil: Date) throws {
    let nowValue = now.timeIntervalSince1970
    let leaseValue = leaseUntil.timeIntervalSince1970
    let duration = leaseValue - nowValue
    guard nowValue.isFinite, leaseValue.isFinite, duration > 0, duration <= 3_600 else {
      throw EventStoreError.invalidArgument("leaseUntil")
    }
  }

  private static func validLedgerKey(_ value: String, maximumBytes: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
