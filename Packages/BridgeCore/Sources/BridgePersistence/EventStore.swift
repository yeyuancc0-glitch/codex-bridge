import BridgeDomain
import Foundation
import GRDB

public actor EventStore {
  private let database: DatabaseQueue

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

  public func append(
    _ event: TaskEventEnvelope,
    expectedLastSequence: Int64
  ) throws {
    guard expectedLastSequence >= 0 else {
      throw EventStoreError.invalidArgument("expectedLastSequence")
    }

    let (nextSequence, overflow) = expectedLastSequence.addingReportingOverflow(1)
    guard !overflow, event.sequence == nextSequence else {
      throw EventStoreError.invalidEventSequence(
        expected: overflow ? Int64.max : nextSequence,
        actual: event.sequence
      )
    }

    try database.write { db in
      try Self.ensureTask(event.taskID, createdAt: event.createdAt, in: db)
      try db.execute(
        sql: """
          UPDATE tasks
          SET last_event_seq = ?, updated_at = ?
          WHERE task_id = ? AND last_event_seq = ?
          """,
        arguments: [
          event.sequence,
          event.createdAt.timeIntervalSince1970,
          event.taskID.rawValue,
          expectedLastSequence,
        ]
      )

      guard db.changesCount == 1 else {
        let actual =
          try Int64.fetchOne(
            db,
            sql: "SELECT last_event_seq FROM tasks WHERE task_id = ?",
            arguments: [event.taskID.rawValue]
          ) ?? 0
        throw EventStoreError.optimisticConcurrencyConflict(
          taskID: event.taskID,
          expectedLastSequence: expectedLastSequence,
          actualLastSequence: actual
        )
      }

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
  }

  public func events(
    for taskID: TaskID,
    afterSequence: Int64 = 0
  ) throws -> [TaskEventEnvelope] {
    try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT task_id, seq, schema_version, source, kind, severity, payload, created_at
          FROM task_events
          WHERE task_id = ? AND seq > ?
          ORDER BY seq ASC
          """,
        arguments: [taskID.rawValue, afterSequence]
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

  public func taskIDs() throws -> [TaskID] {
    try database.read { db in
      try String.fetchAll(db, sql: "SELECT task_id FROM tasks ORDER BY created_at, task_id")
        .map(TaskID.init(rawValue:))
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
