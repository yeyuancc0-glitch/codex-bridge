import BridgeDomain
import Foundation
import GRDB

public actor EventStore {
  private enum LockMutation {
    case none
    case releaseOwned
    case rekeyOwned(from: [String], to: [String])
  }

  private let database: DatabaseQueue
  private var changeContinuations: [UUID: AsyncStream<TaskID>.Continuation] = [:]

  public init(path: String) throws {
    guard !path.isEmpty else {
      throw EventStoreError.invalidArgument("path")
    }

    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    let database = try DatabaseQueue(path: path, configuration: configuration)
    try EventStoreSchema.migrate(database)
    self.database = database
  }

  public static func inMemory() throws -> EventStore {
    try EventStore(path: ":memory:")
  }

  public func taskChanges() -> AsyncStream<TaskID> {
    let identifier = UUID()
    let pair = AsyncStream.makeStream(
      of: TaskID.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    changeContinuations[identifier] = pair.continuation
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.removeChangeContinuation(identifier) }
    }
    return pair.stream
  }

  public func append(
    _ event: TaskEventEnvelope,
    expectedLastSequence: Int64,
    snapshot: TaskStateSnapshot? = nil
  ) throws {
    try persist(
      [event],
      expectedLastSequence: expectedLastSequence,
      lockMutation: .none,
      snapshot: snapshot
    )
  }

  public func appendReleasingOwnedLocks(
    _ event: TaskEventEnvelope,
    expectedLastSequence: Int64,
    snapshot: TaskStateSnapshot? = nil
  ) throws {
    try persist(
      [event],
      expectedLastSequence: expectedLastSequence,
      lockMutation: .releaseOwned,
      snapshot: snapshot
    )
  }

  public func appendRekeyingOwnedLocks(
    _ event: TaskEventEnvelope,
    expectedLastSequence: Int64,
    from currentLockKeys: [String],
    to replacementLockKeys: [String],
    snapshot: TaskStateSnapshot? = nil
  ) throws {
    let current = try Self.validatedLockKeys(
      currentLockKeys,
      ownerTaskID: event.taskID
    )
    let replacement = try Self.validatedLockKeys(
      replacementLockKeys,
      ownerTaskID: event.taskID
    )
    try persist(
      [event],
      expectedLastSequence: expectedLastSequence,
      lockMutation: .rekeyOwned(from: current, to: replacement),
      snapshot: snapshot
    )
  }

  public func appendBatchReleasingOwnedLocks(
    _ events: [TaskEventEnvelope],
    expectedLastSequence: Int64,
    snapshot: TaskStateSnapshot
  ) throws {
    try persist(
      events,
      expectedLastSequence: expectedLastSequence,
      lockMutation: .releaseOwned,
      snapshot: snapshot
    )
  }

  private func persist(
    _ events: [TaskEventEnvelope],
    expectedLastSequence: Int64,
    lockMutation: LockMutation,
    snapshot: TaskStateSnapshot?
  ) throws {
    guard expectedLastSequence >= 0 else {
      throw EventStoreError.invalidArgument("expectedLastSequence")
    }
    guard !events.isEmpty, events.count <= 8, let first = events.first, let last = events.last,
      events.allSatisfy({ $0.taskID == first.taskID })
    else {
      throw EventStoreError.invalidArgument("events")
    }
    var expectedSequence = expectedLastSequence
    for event in events {
      let (nextSequence, overflow) = expectedSequence.addingReportingOverflow(1)
      guard !overflow, event.sequence == nextSequence else {
        throw EventStoreError.invalidEventSequence(
          expected: overflow ? Int64.max : nextSequence,
          actual: event.sequence
        )
      }
      expectedSequence = event.sequence
    }
    try Self.validate(snapshot: snapshot, event: last)

    try database.write { db in
      try Self.ensureTask(first.taskID, createdAt: first.createdAt, in: db)
      try db.execute(
        sql: """
          UPDATE tasks
          SET last_event_seq = ?, updated_at = ?
          WHERE task_id = ? AND last_event_seq = ?
          """,
        arguments: [
          last.sequence,
          last.createdAt.timeIntervalSince1970,
          first.taskID.rawValue,
          expectedLastSequence,
        ]
      )

      guard db.changesCount == 1 else {
        let actual =
          try Int64.fetchOne(
            db,
            sql: "SELECT last_event_seq FROM tasks WHERE task_id = ?",
            arguments: [first.taskID.rawValue]
          ) ?? 0
        throw EventStoreError.optimisticConcurrencyConflict(
          taskID: first.taskID,
          expectedLastSequence: expectedLastSequence,
          actualLastSequence: actual
        )
      }

      for event in events {
        try Self.insert(event, in: db)
      }

      if let snapshot {
        try Self.upsert(snapshot, in: db)
      }

      switch lockMutation {
      case .none:
        return
      case .releaseOwned:
        try Self.releaseOwnedLocks(taskID: first.taskID, in: db)
      case .rekeyOwned(let current, let replacement):
        try Self.rekeyOwnedLocks(
          taskID: first.taskID,
          from: current,
          to: replacement,
          acquiredAt: last.createdAt,
          in: db
        )
      }
    }
    publishChange(first.taskID)
  }

  private static func insert(_ event: TaskEventEnvelope, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO task_events (
            task_id, seq, schema_version, source, kind, severity, payload, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        event.taskID.rawValue,
        event.sequence,
        Int(event.schemaVersion),
        event.source,
        event.kind,
        event.severity,
        event.payload,
        event.createdAt.timeIntervalSince1970,
      ]
    )
  }

  private static func releaseOwnedLocks(taskID: TaskID, in db: Database) throws {
    let lockCount =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM locks WHERE owner_task_id = ?",
        arguments: [taskID.rawValue]
      ) ?? 0
    guard lockCount == 0 || lockCount == 2 else {
      throw EventStoreError.invalidLockSet
    }
    try db.execute(
      sql: "DELETE FROM locks WHERE owner_task_id = ?",
      arguments: [taskID.rawValue]
    )
  }

  private static func rekeyOwnedLocks(
    taskID: TaskID,
    from current: [String],
    to replacement: [String],
    acquiredAt: Date,
    in db: Database
  ) throws {
    let owned = try String.fetchAll(
      db,
      sql: "SELECT lock_key FROM locks WHERE owner_task_id = ? ORDER BY lock_key",
      arguments: [taskID.rawValue]
    )
    guard owned == current else { throw EventStoreError.invalidLockSet }
    for key in replacement {
      let owner = try String.fetchOne(
        db,
        sql: "SELECT owner_task_id FROM locks WHERE lock_key = ?",
        arguments: [key]
      )
      guard owner == nil || owner == taskID.rawValue else {
        throw EventStoreError.lockUnavailable(key)
      }
    }
    try db.execute(
      sql: "DELETE FROM locks WHERE owner_task_id = ?",
      arguments: [taskID.rawValue]
    )
    for key in replacement {
      try db.execute(
        sql: "INSERT INTO locks (lock_key, owner_task_id, acquired_at) VALUES (?, ?, ?)",
        arguments: [key, taskID.rawValue, acquiredAt.timeIntervalSince1970]
      )
    }
  }

  public func events(
    for taskID: TaskID,
    afterSequence: Int64 = 0
  ) throws -> [TaskEventEnvelope] {
    try fetchEvents(for: taskID, afterSequence: afterSequence, limit: nil)
  }

  public func events(
    for taskID: TaskID,
    afterSequence: Int64 = 0,
    limit: Int
  ) throws -> [TaskEventEnvelope] {
    guard (1...1_000).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try fetchEvents(for: taskID, afterSequence: afterSequence, limit: limit)
  }

  private func fetchEvents(
    for taskID: TaskID,
    afterSequence: Int64,
    limit: Int?
  ) throws -> [TaskEventEnvelope] {
    try database.read { db in
      let limitClause = limit == nil ? "" : "LIMIT ?"
      var arguments: StatementArguments = [taskID.rawValue, afterSequence]
      if let limit { arguments += [limit] }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT task_id, seq, schema_version, source, kind, severity, payload, created_at
          FROM task_events
          WHERE task_id = ? AND seq > ?
          ORDER BY seq ASC
          \(limitClause)
          """,
        arguments: arguments
      )
      return try rows.map(Self.decodeEvent)
    }
  }

  public func lastEventSequence(for taskID: TaskID) throws -> Int64? {
    try database.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT last_event_seq FROM tasks WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    }
  }

  public func stateSnapshot(for taskID: TaskID) throws -> TaskStateSnapshot? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT task_id, last_event_seq, schema_version, payload, recovery_required
            FROM task_state_snapshots
            WHERE task_id = ?
            """,
          arguments: [taskID.rawValue]
        )
      else { return nil }
      return try Self.decodeSnapshot(row)
    }
  }

  public func saveStateSnapshot(
    _ snapshot: TaskStateSnapshot,
    expectedLastSequence: Int64
  ) throws {
    guard snapshot.lastEventSequence == expectedLastSequence else {
      throw EventStoreError.invalidArgument("snapshot.lastEventSequence")
    }
    try Self.validate(snapshot: snapshot)
    try database.write { db in
      let actual =
        try Int64.fetchOne(
          db,
          sql: "SELECT last_event_seq FROM tasks WHERE task_id = ?",
          arguments: [snapshot.taskID.rawValue]
        ) ?? 0
      guard actual == expectedLastSequence else {
        throw EventStoreError.optimisticConcurrencyConflict(
          taskID: snapshot.taskID,
          expectedLastSequence: expectedLastSequence,
          actualLastSequence: actual
        )
      }
      try Self.upsert(snapshot, in: db)
    }
  }

  public func taskIDs() throws -> [TaskID] {
    try database.read { db in
      try String.fetchAll(db, sql: "SELECT task_id FROM tasks ORDER BY created_at, task_id")
        .map(TaskID.init(rawValue:))
    }
  }

  public func recentlyUpdatedTaskIDs(limit: Int) throws -> [TaskID] {
    guard (1...500).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT task_id FROM tasks ORDER BY updated_at DESC, task_id LIMIT ?",
        arguments: [limit]
      ).map(TaskID.init(rawValue:))
    }
  }

  public func taskIDsRequiringRecovery(
    afterTaskID: TaskID? = nil,
    limit: Int
  ) throws -> [TaskID] {
    guard (1...500).contains(limit) else {
      throw EventStoreError.invalidArgument("limit")
    }
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT tasks.task_id
          FROM tasks
          LEFT JOIN task_state_snapshots
            ON task_state_snapshots.task_id = tasks.task_id
          WHERE tasks.task_id > ?
            AND (
              task_state_snapshots.task_id IS NULL
              OR task_state_snapshots.recovery_required = 1
              OR task_state_snapshots.last_event_seq != tasks.last_event_seq
              OR EXISTS (
                SELECT 1
                FROM locks
                WHERE locks.owner_task_id = tasks.task_id
              )
            )
          ORDER BY tasks.task_id
          LIMIT ?
          """,
        arguments: [afterTaskID?.rawValue ?? "", limit]
      ).map(TaskID.init(rawValue:))
    }
  }

  public func claimSubmission(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String,
    taskID: TaskID,
    createdAt: Date = Date()
  ) throws -> TaskID {
    try Self.validateClaim(
      origin: origin,
      key: key,
      requestFingerprint: requestFingerprint,
      taskID: taskID
    )

    return try database.write { db in
      if let row = try Row.fetchOne(
        db,
        sql: """
          SELECT request_fingerprint, task_id
          FROM submission_claims
          WHERE origin = ? AND idempotency_key = ?
          """,
        arguments: [origin, key.rawValue]
      ) {
        let storedFingerprint: String = row["request_fingerprint"]
        guard storedFingerprint == requestFingerprint else {
          throw EventStoreError.idempotencyMismatch(origin: origin, key: key)
        }
        let storedTaskID: String = row["task_id"]
        return TaskID(rawValue: storedTaskID)
      }

      try Self.ensureTask(taskID, createdAt: createdAt, in: db)
      try db.execute(
        sql: """
          INSERT INTO submission_claims (
              origin, idempotency_key, request_fingerprint, task_id, created_at
          ) VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          origin,
          key.rawValue,
          requestFingerprint,
          taskID.rawValue,
          createdAt.timeIntervalSince1970,
        ]
      )
      return taskID
    }
  }

  public func claimSubmission(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String,
    taskID: TaskID,
    initialEvents: [TaskEventEnvelope],
    initialSnapshot: TaskStateSnapshot? = nil,
    createdAt: Date = Date()
  ) throws -> TaskID {
    try Self.validateClaim(
      origin: origin,
      key: key,
      requestFingerprint: requestFingerprint,
      taskID: taskID
    )
    try Self.validateInitialEvents(initialEvents, taskID: taskID)
    if let initialSnapshot {
      guard let lastEvent = initialEvents.last else {
        throw EventStoreError.invalidArgument("initialSnapshot")
      }
      try Self.validate(snapshot: initialSnapshot, event: lastEvent)
    }

    let claimedTaskID = try database.write { db in
      if let existing = try Self.existingClaim(
        origin: origin,
        key: key,
        requestFingerprint: requestFingerprint,
        in: db
      ) {
        return existing
      }
      try Self.ensureTask(taskID, createdAt: createdAt, in: db)
      try Self.insertClaim(
        origin: origin,
        key: key,
        requestFingerprint: requestFingerprint,
        taskID: taskID,
        createdAt: createdAt,
        in: db
      )
      for event in initialEvents {
        try Self.insertEvent(event, in: db)
      }
      try db.execute(
        sql: "UPDATE tasks SET last_event_seq = ?, updated_at = ? WHERE task_id = ?",
        arguments: [
          initialEvents.last?.sequence ?? 0,
          initialEvents.last?.createdAt.timeIntervalSince1970 ?? createdAt.timeIntervalSince1970,
          taskID.rawValue,
        ]
      )
      if let initialSnapshot {
        try Self.upsert(initialSnapshot, in: db)
      }
      return taskID
    }
    publishChange(claimedTaskID)
    return claimedTaskID
  }

  public func submissionClaim(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String
  ) throws -> TaskID? {
    guard !origin.isEmpty else { throw EventStoreError.invalidArgument("origin") }
    guard !key.rawValue.isEmpty else { throw EventStoreError.invalidArgument("key") }
    guard !requestFingerprint.isEmpty else {
      throw EventStoreError.invalidArgument("requestFingerprint")
    }
    return try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT request_fingerprint, task_id
            FROM submission_claims
            WHERE origin = ? AND idempotency_key = ?
            """,
          arguments: [origin, key.rawValue]
        )
      else {
        return nil
      }
      let storedFingerprint: String = row["request_fingerprint"]
      guard storedFingerprint == requestFingerprint else {
        throw EventStoreError.idempotencyMismatch(origin: origin, key: key)
      }
      return TaskID(rawValue: row["task_id"])
    }
  }

  public func acquireLocks(
    _ lockKeys: [String],
    ownerTaskID: TaskID,
    acquiredAt: Date = Date()
  ) throws {
    let orderedKeys = try Self.validatedLockKeys(lockKeys, ownerTaskID: ownerTaskID)

    try database.write { db in
      try Self.ensureTask(ownerTaskID, createdAt: acquiredAt, in: db)
      for key in orderedKeys {
        do {
          try db.execute(
            sql: """
              INSERT INTO locks (lock_key, owner_task_id, acquired_at)
              VALUES (?, ?, ?)
              """,
            arguments: [key, ownerTaskID.rawValue, acquiredAt.timeIntervalSince1970]
          )
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          throw EventStoreError.lockUnavailable(key)
        }
      }
    }
  }

  public func lockOwner(for lockKey: String) throws -> TaskID? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT owner_task_id FROM locks WHERE lock_key = ?",
        arguments: [lockKey]
      ).map(TaskID.init(rawValue:))
    }
  }

  public func releaseLocks(
    _ lockKeys: [String],
    ownerTaskID: TaskID
  ) throws {
    let orderedKeys = try Self.validatedLockKeys(lockKeys, ownerTaskID: ownerTaskID)
    try database.write { db in
      for key in orderedKeys {
        let owner = try String.fetchOne(
          db,
          sql: "SELECT owner_task_id FROM locks WHERE lock_key = ?",
          arguments: [key]
        )
        guard owner == nil || owner == ownerTaskID.rawValue else {
          throw EventStoreError.lockOwnershipMismatch(key)
        }
      }
      try db.execute(
        sql: "DELETE FROM locks WHERE owner_task_id = ? AND lock_key IN (?, ?)",
        arguments: [ownerTaskID.rawValue, orderedKeys[0], orderedKeys[1]]
      )
    }
  }

  public func lockKeysOwned(by ownerTaskID: TaskID) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT lock_key FROM locks WHERE owner_task_id = ? ORDER BY lock_key",
        arguments: [ownerTaskID.rawValue]
      )
    }
  }

  private func publishChange(_ taskID: TaskID) {
    for continuation in changeContinuations.values {
      continuation.yield(taskID)
    }
  }

  private func removeChangeContinuation(_ identifier: UUID) {
    changeContinuations[identifier] = nil
  }

  private static func ensureTask(
    _ taskID: TaskID,
    createdAt: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO tasks (task_id, last_event_seq, created_at, updated_at)
        VALUES (?, 0, ?, ?)
        ON CONFLICT(task_id) DO NOTHING
        """,
      arguments: [
        taskID.rawValue,
        createdAt.timeIntervalSince1970,
        createdAt.timeIntervalSince1970,
      ]
    )
  }

  private static func validate(
    snapshot: TaskStateSnapshot?,
    event: TaskEventEnvelope
  ) throws {
    guard let snapshot else { return }
    try validate(snapshot: snapshot)
    guard snapshot.taskID == event.taskID,
      snapshot.lastEventSequence == event.sequence
    else {
      throw EventStoreError.invalidArgument("snapshot")
    }
  }

  private static func validate(snapshot: TaskStateSnapshot) throws {
    guard !snapshot.taskID.rawValue.isEmpty,
      snapshot.lastEventSequence > 0,
      !snapshot.payload.isEmpty,
      snapshot.payload.count <= 512 * 1024
    else {
      throw EventStoreError.invalidArgument("snapshot")
    }
  }

  private static func upsert(
    _ snapshot: TaskStateSnapshot,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO task_state_snapshots (
            task_id, last_event_seq, schema_version, payload, recovery_required
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(task_id) DO UPDATE SET
            last_event_seq = excluded.last_event_seq,
            schema_version = excluded.schema_version,
            payload = excluded.payload,
            recovery_required = excluded.recovery_required
        """,
      arguments: [
        snapshot.taskID.rawValue,
        snapshot.lastEventSequence,
        Int(snapshot.schemaVersion),
        snapshot.payload,
        snapshot.recoveryRequired,
      ]
    )
  }

  private static func decodeSnapshot(_ row: Row) throws -> TaskStateSnapshot {
    let taskID = TaskID(rawValue: row["task_id"])
    let sequence: Int64 = row["last_event_seq"]
    let storedSchemaVersion: Int64 = row["schema_version"]
    let payload: Data = row["payload"]
    let storedRecoveryRequired: Int64 = row["recovery_required"]
    guard !taskID.rawValue.isEmpty,
      sequence > 0,
      let schemaVersion = UInt16(exactly: storedSchemaVersion),
      !payload.isEmpty,
      payload.count <= 512 * 1024,
      storedRecoveryRequired == 0 || storedRecoveryRequired == 1
    else {
      throw EventStoreError.corruptEvent(taskID: taskID, sequence: sequence)
    }
    return TaskStateSnapshot(
      taskID: taskID,
      lastEventSequence: sequence,
      schemaVersion: schemaVersion,
      payload: payload,
      recoveryRequired: storedRecoveryRequired == 1
    )
  }

  private static func existingClaim(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String,
    in db: Database
  ) throws -> TaskID? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT request_fingerprint, task_id
          FROM submission_claims
          WHERE origin = ? AND idempotency_key = ?
          """,
        arguments: [origin, key.rawValue]
      )
    else {
      return nil
    }
    let storedFingerprint: String = row["request_fingerprint"]
    guard storedFingerprint == requestFingerprint else {
      throw EventStoreError.idempotencyMismatch(origin: origin, key: key)
    }
    return TaskID(rawValue: row["task_id"])
  }

  private static func insertClaim(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String,
    taskID: TaskID,
    createdAt: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO submission_claims (
            origin, idempotency_key, request_fingerprint, task_id, created_at
        ) VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        origin,
        key.rawValue,
        requestFingerprint,
        taskID.rawValue,
        createdAt.timeIntervalSince1970,
      ]
    )
  }

  private static func insertEvent(_ event: TaskEventEnvelope, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO task_events (
            task_id, seq, schema_version, source, kind, severity, payload, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        event.taskID.rawValue,
        event.sequence,
        Int(event.schemaVersion),
        event.source,
        event.kind,
        event.severity,
        event.payload,
        event.createdAt.timeIntervalSince1970,
      ]
    )
  }

  private static func decodeEvent(_ row: Row) throws -> TaskEventEnvelope {
    let taskID = TaskID(rawValue: row["task_id"])
    let sequence: Int64 = row["seq"]
    let storedSchemaVersion: Int64 = row["schema_version"]
    guard let schemaVersion = UInt16(exactly: storedSchemaVersion) else {
      throw EventStoreError.corruptEvent(taskID: taskID, sequence: sequence)
    }

    let timestamp: Double = row["created_at"]
    return TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: schemaVersion,
      source: row["source"],
      kind: row["kind"],
      severity: row["severity"],
      payload: row["payload"],
      createdAt: Date(timeIntervalSince1970: timestamp)
    )
  }

  private static func validateClaim(
    origin: String,
    key: IdempotencyKey,
    requestFingerprint: String,
    taskID: TaskID
  ) throws {
    guard !origin.isEmpty else { throw EventStoreError.invalidArgument("origin") }
    guard !key.rawValue.isEmpty else { throw EventStoreError.invalidArgument("key") }
    guard !requestFingerprint.isEmpty else {
      throw EventStoreError.invalidArgument("requestFingerprint")
    }
    guard !taskID.rawValue.isEmpty else { throw EventStoreError.invalidArgument("taskID") }
  }

  private static func validateInitialEvents(
    _ events: [TaskEventEnvelope],
    taskID: TaskID
  ) throws {
    guard !events.isEmpty else { throw EventStoreError.invalidArgument("initialEvents") }
    for (index, event) in events.enumerated() {
      guard event.taskID == taskID, event.sequence == Int64(index + 1) else {
        throw EventStoreError.invalidArgument("initialEvents")
      }
      guard event.createdAt.timeIntervalSince1970.isFinite else {
        throw EventStoreError.invalidArgument("initialEvents")
      }
    }
  }

  private static func validatedLockKeys(
    _ lockKeys: [String],
    ownerTaskID: TaskID
  ) throws -> [String] {
    guard lockKeys.count == 2, Set(lockKeys).count == 2 else {
      throw EventStoreError.invalidLockSet
    }
    guard lockKeys.allSatisfy({ !$0.isEmpty }), !ownerTaskID.rawValue.isEmpty else {
      throw EventStoreError.invalidLockSet
    }
    return lockKeys.sorted()
  }
}
