import BridgeDomain
import BridgeSupervisor
import Crypto
import Foundation
import GRDB

public actor DurableSupervisionLedger: DurableSupervisionRetentionStore {
  public static let maximumActiveScopes = 128
  public static let maximumCheckpointsPerActiveScope = 256
  public static let maximumReviewsPerActiveScope = 512
  public static let maximumActionsPerActiveScope = 512
  public static let maximumOpenActions = 512
  public static let maximumActiveRecoveryRecords = 512
  public static let maximumActiveRecoveryPayloadBytes = 32 * 1_024 * 1_024
  public static let maximumQueryLimit = 500

  private let database: DatabaseQueue

  public init(path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else {
      throw DurableSupervisionLedgerError.invalidArgument("path")
    }
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    do {
      database = try DatabaseQueue(path: path, configuration: configuration)
    } catch {
      throw DurableSupervisionLedgerError.databaseUnavailable
    }
    try DurableSupervisionSchema.prepare(database)
    try Self.validateActiveRecords(in: database)
  }

  public static func inMemory() throws -> DurableSupervisionLedger {
    try DurableSupervisionLedger(path: ":memory:")
  }

  @discardableResult
  public func begin(
    scope: DurableSupervisionScope,
    configuration: SupervisorGuardConfiguration,
    at date: Date = Date()
  ) throws -> DurableSupervisionStateRecord {
    try Self.validate(date: date, field: "date")
    let date = Self.normalized(date)
    let configurationJSON = try Self.canonicalJSON(configuration)
    let initialState = SupervisorGuardState()
    let stateJSON = try Self.canonicalJSON(initialState)
    return try database.write { db in
      if let current = try Self.fetchCurrentScope(taskID: scope.taskID, in: db) {
        return try Self.beginReplacing(
          current,
          with: scope,
          configuration: configuration,
          configurationJSON: configurationJSON,
          state: initialState,
          stateJSON: stateJSON,
          at: date,
          in: db
        )
      }
      try Self.requireActiveScopeCapacity(in: db)
      try Self.requireActiveRecoveryCapacity(
        additionalRecords: 1,
        additionalPayloadBytes: Int64(configurationJSON.count + stateJSON.count),
        in: db
      )
      try Self.insertScope(
        scope,
        configurationJSON: configurationJSON,
        stateJSON: stateJSON,
        at: date,
        in: db
      )
      try Self.setCurrent(scope, in: db)
      return Self.makeStateRecord(
        scope: scope,
        status: .active,
        configuration: configuration,
        state: initialState,
        statePayload: stateJSON,
        createdAt: date,
        updatedAt: date
      )
    }
  }

  @discardableResult
  public func appendCheckpoint(
    scope: DurableSupervisionScope,
    checkpoint: SupervisorCheckpoint,
    at date: Date = Date()
  ) throws -> DurableSupervisorCheckpointRecord {
    try Self.validate(date: date, field: "date")
    let date = Self.normalized(date)
    try Self.validate(checkpoint: checkpoint, scope: scope)
    let payload = try Self.canonicalJSON(checkpoint)
    return try database.write { db in
      _ = try Self.requireActiveCurrentScope(scope, in: db)
      if let stored = try Self.fetchCheckpoint(
        scope: scope,
        sequence: checkpoint.sequence,
        in: db
      ) {
        guard stored.payload == payload else {
          throw DurableSupervisionLedgerError.checkpointConflict(
            sequence: checkpoint.sequence
          )
        }
        return stored.record
      }
      try Self.requireCapacity(
        table: "bridge_supervision_checkpoints",
        scope: scope,
        maximum: Self.maximumCheckpointsPerActiveScope,
        in: db
      )
      try Self.requireActiveRecoveryCapacity(
        additionalRecords: 1,
        additionalPayloadBytes: Int64(payload.count),
        in: db
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_supervision_checkpoints (
            task_id, generation, checkpoint_sequence, checkpoint_json,
            checkpoint_sha256, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, Int64(checkpoint.sequence), payload,
          Self.digest(payload), date.timeIntervalSince1970,
        ]
      )
      return Self.makeCheckpointRecord(
        scope: scope,
        checkpoint: checkpoint,
        payload: payload,
        createdAt: date
      )
    }
  }

  @discardableResult
  public func appendReview(
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    result: DurableSupervisorReviewResult,
    taskEventSequence: Int64? = nil,
    at date: Date = Date()
  ) throws -> DurableSupervisionReviewRecord {
    try Self.validate(date: date, field: "date")
    let date = Self.normalized(date)
    guard position.checkpointSequence > 0,
      position.checkpointSequence <= UInt64(Int64.max)
    else { throw DurableSupervisionLedgerError.invalidArgument("position") }
    let resolvedTaskEventSequence = taskEventSequence ?? Int64(position.checkpointSequence)
    guard resolvedTaskEventSequence > 0 else {
      throw DurableSupervisionLedgerError.invalidArgument("taskEventSequence")
    }
    let resultJSON = try Self.canonicalJSON(result)
    return try database.write { db in
      let scopeRecord = try Self.requireActiveCurrentScope(scope, in: db)
      guard
        let checkpoint = try Self.fetchCheckpoint(
          scope: scope,
          sequence: position.checkpointSequence,
          in: db
        )
      else {
        throw DurableSupervisionLedgerError.invalidArgument("checkpoint")
      }
      if let stored = try Self.fetchReview(scope: scope, position: position, in: db) {
        guard stored.resultPayload == resultJSON else {
          throw DurableSupervisionLedgerError.reviewConflict(position)
        }
        let record = try Self.makeReviewRecord(stored, scope: scope, in: db)
        guard
          record.action?.taskEventSequence == nil
            || record.action?.taskEventSequence == resolvedTaskEventSequence
        else {
          throw DurableSupervisionLedgerError.reviewConflict(position)
        }
        return record
      }
      try Self.requireNew(position: position, after: scopeRecord.state.lastReviewPosition)
      try Self.requireCapacity(
        table: "bridge_supervision_decisions",
        scope: scope,
        maximum: Self.maximumReviewsPerActiveScope,
        in: db
      )
      return try Self.insertReview(
        scope: scope,
        scopeRecord: scopeRecord,
        position: position,
        result: result,
        resultJSON: resultJSON,
        checkpoint: checkpoint.record.checkpoint,
        taskEventSequence: resolvedTaskEventSequence,
        at: date,
        in: db
      )
    }
  }

  public func state(for taskID: TaskID) throws -> DurableSupervisionStateRecord? {
    try database.read { db in
      try Self.fetchCurrentScope(taskID: taskID, in: db)?.record
    }
  }

  public func state(for scope: DurableSupervisionScope) throws -> DurableSupervisionStateRecord? {
    try database.read { db in
      try Self.fetchScope(scope: scope, in: db)?.record
    }
  }

  public func checkpoints(
    for scope: DurableSupervisionScope,
    after sequence: UInt64 = 0,
    limit: Int = 100
  ) throws -> [DurableSupervisorCheckpointRecord] {
    try Self.validate(limit: limit)
    guard sequence <= UInt64(Int64.max) else {
      throw DurableSupervisionLedgerError.invalidArgument("sequence")
    }
    return try database.read { db in
      try Self.requireScope(scope, in: db)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM bridge_supervision_checkpoints
          WHERE task_id = ? AND generation = ? AND checkpoint_sequence > ?
          ORDER BY checkpoint_sequence ASC LIMIT ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation, Int64(sequence), limit]
      )
      return try rows.map { try Self.decodeCheckpoint($0, scope: scope).record }
    }
  }

  public func reviews(
    for scope: DurableSupervisionScope,
    after position: SupervisorReviewPosition? = nil,
    limit: Int = 100
  ) throws -> [DurableSupervisionReviewRecord] {
    try Self.validate(limit: limit)
    if let position, position.checkpointSequence > UInt64(Int64.max) {
      throw DurableSupervisionLedgerError.invalidArgument("position")
    }
    return try database.read { db in
      try Self.requireScope(scope, in: db)
      let rows = try Self.fetchReviewRows(
        scope: scope,
        after: position,
        limit: limit,
        in: db
      )
      return try rows.map { row in
        try Self.makeReviewRecord(Self.decodeReview(row), scope: scope, in: db)
      }
    }
  }

  public func evidenceSummary(
    for scope: DurableSupervisionScope
  ) throws -> DurableSupervisionEvidenceSummary {
    try database.read { db in
      let storedScope = try Self.fetchScope(scope: scope, in: db)
      guard let storedScope else {
        throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
      }
      return try Self.makeEvidenceSummary(scope: storedScope, in: db)
    }
  }

  public func pendingActions(limit: Int = 100) throws -> [DurableSupervisorActionRecord] {
    try actions(state: .pending, limit: limit)
  }

  public func ambiguousActions(limit: Int = 100) throws -> [DurableSupervisorActionRecord] {
    try actions(state: .ambiguous, limit: limit)
  }

  @discardableResult
  public func beginActionAttempt(
    id: String,
    at date: Date = Date()
  ) throws -> DurableSupervisorActionRecord {
    try transitionAction(id: id, from: .pending, to: .ambiguous, at: date)
  }

  @discardableResult
  public func markActionApplied(
    id: String,
    at date: Date = Date()
  ) throws -> DurableSupervisorActionRecord {
    try transitionAction(
      id: id,
      from: .ambiguous,
      to: .applied,
      idempotentTarget: true,
      at: date
    )
  }

  @discardableResult
  public func supersedeAction(
    id: String,
    at date: Date = Date()
  ) throws -> DurableSupervisorActionRecord {
    try transitionAction(
      id: id,
      from: .pending,
      to: .superseded,
      idempotentTarget: true,
      at: date
    )
  }

  @discardableResult
  public func close(
    scope: DurableSupervisionScope,
    at date: Date = Date()
  ) throws -> DurableSupervisionStateRecord {
    try transitionScope(scope, to: .completed, at: date)
  }

  @discardableResult
  public func supersede(
    scope: DurableSupervisionScope,
    at date: Date = Date()
  ) throws -> DurableSupervisionStateRecord {
    try transitionScope(scope, to: .superseded, at: date)
  }

  public func discardForRetention(
    taskID: TaskID
  ) throws -> DurableSupervisionRetentionRemoval {
    try database.write { db in
      let generations =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM bridge_supervision_scopes WHERE task_id = ?",
          arguments: [taskID.rawValue]
        ) ?? 0
      guard generations > 0 else { return .alreadyAbsent }
      let active =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM bridge_supervision_scopes
              WHERE task_id = ? AND status = 'active'
            )
            """,
          arguments: [taskID.rawValue]
        ) ?? false
      guard !active else { throw DurableSupervisionLedgerError.retentionBlocked(taskID) }
      try db.execute(sql: "DROP TRIGGER bridge_supervision_checkpoints_no_delete")
      try db.execute(sql: "DROP TRIGGER bridge_supervision_decisions_no_delete")
      try db.execute(
        sql: "DELETE FROM bridge_supervision_actions WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_supervision_decisions WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_supervision_checkpoints WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_supervision_current_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: "DELETE FROM bridge_supervision_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
      try db.execute(
        sql: """
          CREATE TRIGGER bridge_supervision_checkpoints_no_delete
          BEFORE DELETE ON bridge_supervision_checkpoints
          BEGIN SELECT RAISE(ABORT, 'supervision checkpoints are append-only'); END;
          CREATE TRIGGER bridge_supervision_decisions_no_delete
          BEFORE DELETE ON bridge_supervision_decisions
          BEGIN SELECT RAISE(ABORT, 'supervision decisions are append-only'); END;
          """)
      return .removed(generations)
    }
  }

  private func actions(
    state: DurableSupervisorActionState,
    limit: Int
  ) throws -> [DurableSupervisorActionRecord] {
    try Self.validate(limit: limit)
    return try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT a.*, s.project_id, s.thread_id, s.turn_id
          FROM bridge_supervision_actions a
          JOIN bridge_supervision_scopes s
            ON s.task_id = a.task_id AND s.generation = a.generation
          JOIN bridge_supervision_current_scopes c
            ON c.task_id = a.task_id AND c.generation = a.generation
          WHERE a.state = ? AND s.status = 'active'
          ORDER BY a.updated_at ASC, a.action_id ASC LIMIT ?
          """,
        arguments: [state.rawValue, limit]
      )
      return try rows.map(Self.decodeJoinedAction)
    }
  }

  private func transitionAction(
    id: String,
    from source: DurableSupervisorActionState,
    to target: DurableSupervisorActionState,
    idempotentTarget: Bool = false,
    at date: Date
  ) throws -> DurableSupervisorActionRecord {
    try Self.validateActionID(id)
    try Self.validate(date: date, field: "date")
    let date = Self.normalized(date)
    return try database.write { db in
      guard let current = try Self.fetchJoinedAction(id: id, in: db) else {
        throw DurableSupervisionLedgerError.actionNotFound(id)
      }
      if idempotentTarget, current.state == target { return current }
      guard current.state == source else {
        throw DurableSupervisionLedgerError.invalidActionTransition(
          from: current.state,
          to: target
        )
      }
      try db.execute(
        sql: """
          UPDATE bridge_supervision_actions SET state = ?, updated_at = ?
          WHERE action_id = ? AND state = ?
          """,
        arguments: [target.rawValue, date.timeIntervalSince1970, id, source.rawValue]
      )
      guard db.changesCount == 1 else {
        throw DurableSupervisionLedgerError.actionConflict(id)
      }
      return DurableSupervisorActionRecord(
        id: current.id,
        scope: current.scope,
        position: current.position,
        taskEventSequence: current.taskEventSequence,
        kind: current.kind,
        instruction: current.instruction,
        state: target,
        createdAt: current.createdAt,
        updatedAt: date
      )
    }
  }

  private func transitionScope(
    _ scope: DurableSupervisionScope,
    to target: DurableSupervisionScopeStatus,
    at date: Date
  ) throws -> DurableSupervisionStateRecord {
    try Self.validate(date: date, field: "date")
    let date = Self.normalized(date)
    return try database.write { db in
      let current = try Self.requireCurrentScope(scope, in: db)
      if current.status == target { return current.record }
      guard current.status == .active else {
        throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
      }
      let open =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM bridge_supervision_actions
            WHERE task_id = ? AND generation = ? AND state IN ('pending', 'ambiguous')
            """,
          arguments: [scope.taskID.rawValue, scope.generation]
        ) ?? 0
      guard open == 0 else { throw DurableSupervisionLedgerError.pendingActions }
      try db.execute(
        sql: """
          UPDATE bridge_supervision_scopes SET status = ?, updated_at = ?
          WHERE task_id = ? AND generation = ? AND status = 'active'
          """,
        arguments: [
          target.rawValue, date.timeIntervalSince1970, scope.taskID.rawValue, scope.generation,
        ]
      )
      guard db.changesCount == 1 else {
        throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
      }
      return Self.makeStateRecord(
        scope: scope,
        status: target,
        configuration: current.configuration,
        state: current.state,
        statePayload: current.statePayload,
        createdAt: current.createdAt,
        updatedAt: date
      )
    }
  }
}
