import BridgeDomain
import BridgeSupervisor
import CryptoKit
import Foundation
import GRDB

extension DurableSupervisionLedger {
  struct StoredScope {
    let record: DurableSupervisionStateRecord
    let configurationPayload: Data
    let statePayload: Data

    var scope: DurableSupervisionScope { record.scope }
    var status: DurableSupervisionScopeStatus { record.status }
    var configuration: SupervisorGuardConfiguration { record.configuration }
    var state: SupervisorGuardState { record.state }
    var createdAt: Date { record.createdAt }
  }

  struct StoredCheckpoint {
    let record: DurableSupervisorCheckpointRecord
    let payload: Data
  }

  struct StoredReview {
    let position: SupervisorReviewPosition
    let result: DurableSupervisorReviewResult
    let resultPayload: Data
    let state: SupervisorGuardState
    let statePayload: Data
    let createdAt: Date
  }

  struct ActionSeed: Codable {
    let taskID: String
    let generation: Int64
    let checkpointSequence: UInt64
    let attempt: UInt16
    let kind: DurableSupervisorActionKind
    let instruction: String
  }

  static func beginReplacing(
    _ current: StoredScope,
    with scope: DurableSupervisionScope,
    configuration: SupervisorGuardConfiguration,
    configurationJSON: Data,
    state: SupervisorGuardState,
    stateJSON: Data,
    at date: Date,
    in db: Database
  ) throws -> DurableSupervisionStateRecord {
    if current.scope == scope {
      guard current.configurationPayload == configurationJSON else {
        throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
      }
      return current.record
    }
    guard current.status.isTerminal, scope.generation > current.scope.generation else {
      throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
    }
    try requireActiveScopeCapacity(in: db)
    try requireActiveRecoveryCapacity(
      additionalRecords: 1,
      additionalPayloadBytes: Int64(configurationJSON.count + stateJSON.count),
      in: db
    )
    try insertScope(
      scope,
      configurationJSON: configurationJSON,
      stateJSON: stateJSON,
      at: date,
      in: db
    )
    try setCurrent(scope, in: db)
    return makeStateRecord(
      scope: scope,
      status: .active,
      configuration: configuration,
      state: state,
      statePayload: stateJSON,
      createdAt: date,
      updatedAt: date
    )
  }

  static func insertScope(
    _ scope: DurableSupervisionScope,
    configurationJSON: Data,
    stateJSON: Data,
    at date: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_supervision_scopes (
          task_id, generation, project_id, thread_id, turn_id, status,
          configuration_json, configuration_sha256, reducer_state_json,
          reducer_state_sha256, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        scope.taskID.rawValue, scope.generation, scope.projectID.rawValue,
        scope.threadID.rawValue, scope.turnID.rawValue, configurationJSON,
        digest(configurationJSON), stateJSON, digest(stateJSON), date.timeIntervalSince1970,
        date.timeIntervalSince1970,
      ]
    )
  }

  static func setCurrent(_ scope: DurableSupervisionScope, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_supervision_current_scopes (task_id, generation) VALUES (?, ?)
        ON CONFLICT(task_id) DO UPDATE SET generation = excluded.generation
        """,
      arguments: [scope.taskID.rawValue, scope.generation]
    )
  }

  static func insertReview(
    scope: DurableSupervisionScope,
    scopeRecord: StoredScope,
    position: SupervisorReviewPosition,
    result: DurableSupervisorReviewResult,
    resultJSON: Data,
    checkpoint: SupervisorCheckpoint,
    at date: Date,
    in db: Database
  ) throws -> DurableSupervisionReviewRecord {
    try validate(result: result, checkpoint: checkpoint)
    var reducer = SupervisorReducer(
      configuration: scopeRecord.configuration,
      state: scopeRecord.state
    )
    let action = reducer.apply(outcome(result, position: position, checkpoint: checkpoint))
    let stateJSON = try canonicalJSON(reducer.state)
    let durableCommand = durableAction(action)
    let actionBytes = durableCommand.map { $0.instruction.utf8.count } ?? 0
    try requireActiveRecoveryCapacity(
      additionalRecords: durableCommand == nil ? 1 : 2,
      additionalPayloadBytes: Int64(
        resultJSON.count + stateJSON.count + actionBytes - scopeRecord.statePayload.count
      ),
      in: db
    )
    try db.execute(
      sql: """
        INSERT INTO bridge_supervision_decisions (
          task_id, generation, checkpoint_sequence, attempt, result_json, result_sha256,
          reducer_state_json, reducer_state_sha256, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        scope.taskID.rawValue, scope.generation, Int64(position.checkpointSequence),
        Int(position.attempt), resultJSON, digest(resultJSON), stateJSON, digest(stateJSON),
        date.timeIntervalSince1970,
      ]
    )
    try updateScopeState(
      scope: scope,
      oldStatePayload: scopeRecord.statePayload,
      newStatePayload: stateJSON,
      at: date,
      in: db
    )
    let actionRecord = try insertActionIfNeeded(
      action,
      scope: scope,
      position: position,
      at: date,
      in: db
    )
    return DurableSupervisionReviewRecord(
      scope: scope,
      position: position,
      result: result,
      state: reducer.state,
      stateDigest: hexDigest(stateJSON),
      action: actionRecord,
      createdAt: date
    )
  }

  static func updateScopeState(
    scope: DurableSupervisionScope,
    oldStatePayload: Data,
    newStatePayload: Data,
    at date: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        UPDATE bridge_supervision_scopes
        SET reducer_state_json = ?, reducer_state_sha256 = ?, updated_at = ?
        WHERE task_id = ? AND generation = ? AND status = 'active'
          AND reducer_state_sha256 = ?
        """,
      arguments: [
        newStatePayload, digest(newStatePayload), date.timeIntervalSince1970,
        scope.taskID.rawValue, scope.generation, digest(oldStatePayload),
      ]
    )
    guard db.changesCount == 1 else {
      throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
    }
  }

  static func insertActionIfNeeded(
    _ action: SupervisorAction,
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    at date: Date,
    in db: Database
  ) throws -> DurableSupervisorActionRecord? {
    guard let command = durableAction(action) else { return nil }
    try requireCapacity(
      table: "bridge_supervision_actions",
      scope: scope,
      maximum: maximumActionsPerActiveScope,
      in: db
    )
    try requireOpenActionCapacity(in: db)
    let id = try actionID(
      scope: scope,
      position: position,
      kind: command.kind,
      instruction: command.instruction
    )
    let instructionData = Data(command.instruction.utf8)
    try db.execute(
      sql: """
        INSERT INTO bridge_supervision_actions (
          action_id, task_id, generation, checkpoint_sequence, attempt, kind,
          instruction, instruction_sha256, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
        """,
      arguments: [
        id, scope.taskID.rawValue, scope.generation, Int64(position.checkpointSequence),
        Int(position.attempt), command.kind.rawValue, command.instruction,
        digest(instructionData), date.timeIntervalSince1970, date.timeIntervalSince1970,
      ]
    )
    return DurableSupervisorActionRecord(
      id: id,
      scope: scope,
      position: position,
      kind: command.kind,
      instruction: command.instruction,
      state: .pending,
      createdAt: date,
      updatedAt: date
    )
  }

  static func durableAction(_ action: SupervisorAction)
    -> (kind: DurableSupervisorActionKind, instruction: String)?
  {
    switch action {
    case .steer(let instruction): return (.steer, instruction)
    case .requestSuspend(let reason): return (.suspend, pauseReason(reason))
    case .interrupt(let reason): return (.interrupt, reason)
    case .requireHumanReview(let reason): return (.suspend, humanReviewReason(reason))
    case .semanticSupervisionUnavailable:
      return (.suspend, "Semantic supervision is unavailable.")
    default: return nil
    }
  }

  static func pauseReason(_ reason: SupervisorPauseReason) -> String {
    switch reason {
    case .supervisorDecision(let summary): summary
    case .semanticSupervisionUnavailable: "Semantic supervision is unavailable."
    }
  }

  static func humanReviewReason(_ reason: SupervisorHumanReviewReason) -> String {
    switch reason {
    case .repeatedIssue(let issue): "Repeated supervisor issue requires review: \(issue)"
    case .turnSteerLimitReached(let turn): "Turn steer limit reached: \(turn)"
    case .taskSteerLimitReached: "Task steer limit reached."
    case .semanticSupervisionUnavailable: "Semantic supervision is unavailable."
    }
  }

  static func outcome(
    _ result: DurableSupervisorReviewResult,
    position: SupervisorReviewPosition,
    checkpoint: SupervisorCheckpoint
  ) -> SupervisorReviewOutcome {
    switch result {
    case .decision(let decision):
      .decision(position: position, checkpoint: checkpoint, decision: decision)
    case .invalidJSON: .invalidJSON(position: position)
    case .modelFailure(let failure): .modelFailure(position: position, failure: failure)
    }
  }

  static func validate(
    result: DurableSupervisorReviewResult,
    checkpoint: SupervisorCheckpoint
  ) throws {
    guard case .decision(let decision) = result else { return }
    guard decision.decision != .finalAccept || checkpoint.stage == .final else {
      throw DurableSupervisionLedgerError.invalidArgument("finalAccept")
    }
  }

  static func requireNew(
    position: SupervisorReviewPosition,
    after previous: SupervisorReviewPosition?
  ) throws {
    guard previous.map({ $0 < position }) ?? true else {
      throw DurableSupervisionLedgerError.invalidArgument("position")
    }
  }

  static func requireCapacity(
    table: String,
    scope: DurableSupervisionScope,
    maximum: Int,
    in db: Database
  ) throws {
    let count =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM \(table) WHERE task_id = ? AND generation = ?",
        arguments: [scope.taskID.rawValue, scope.generation]
      ) ?? 0
    guard count < maximum else {
      throw DurableSupervisionLedgerError.limitExceeded(field: table, maximum: maximum)
    }
  }

  static func requireActiveScopeCapacity(in db: Database) throws {
    let count =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM bridge_supervision_scopes WHERE status = 'active'"
      ) ?? 0
    guard count < maximumActiveScopes else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeScopes",
        maximum: maximumActiveScopes
      )
    }
  }

  struct ActiveRecoveryBudget {
    let records: Int64
    let payloadBytes: Int64
  }

  static func activeRecoveryBudget(in db: Database) throws -> ActiveRecoveryBudget {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          WITH active_scopes AS (
            SELECT s.task_id, s.generation
            FROM bridge_supervision_current_scopes c
            JOIN bridge_supervision_scopes s
              ON s.task_id = c.task_id AND s.generation = c.generation
            WHERE s.status = 'active'
          ), active_recovery AS (
            SELECT COUNT(*) AS record_count,
                   COALESCE(SUM(LENGTH(s.configuration_json)
                     + LENGTH(s.reducer_state_json)), 0) AS payload_bytes
            FROM bridge_supervision_scopes s
            JOIN active_scopes a
              ON a.task_id = s.task_id AND a.generation = s.generation
            UNION ALL
            SELECT COUNT(*), COALESCE(SUM(LENGTH(c.checkpoint_json)), 0)
            FROM bridge_supervision_checkpoints c
            JOIN active_scopes a
              ON a.task_id = c.task_id AND a.generation = c.generation
            UNION ALL
            SELECT COUNT(*), COALESCE(SUM(LENGTH(d.result_json)
              + LENGTH(d.reducer_state_json)), 0)
            FROM bridge_supervision_decisions d
            JOIN active_scopes a
              ON a.task_id = d.task_id AND a.generation = d.generation
            UNION ALL
            SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(x.instruction AS BLOB))), 0)
            FROM bridge_supervision_actions x
            JOIN active_scopes a
              ON a.task_id = x.task_id AND a.generation = x.generation
          )
          SELECT COALESCE(SUM(record_count), 0) AS records,
                 COALESCE(SUM(payload_bytes), 0) AS payload_bytes
          FROM active_recovery
          """
      )
    else { throw DurableSupervisionLedgerError.corruptRecord }
    let records: Int64 = row["records"]
    let payloadBytes: Int64 = row["payload_bytes"]
    guard records >= 0, payloadBytes >= 0 else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    return ActiveRecoveryBudget(records: records, payloadBytes: payloadBytes)
  }

  static func requireActiveRecoveryCapacity(
    additionalRecords: Int,
    additionalPayloadBytes: Int64,
    in db: Database
  ) throws {
    guard additionalRecords >= 0 else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let budget = try activeRecoveryBudget(in: db)
    let (records, recordOverflow) = budget.records.addingReportingOverflow(
      Int64(additionalRecords)
    )
    let (payloadBytes, payloadOverflow) = budget.payloadBytes.addingReportingOverflow(
      additionalPayloadBytes
    )
    guard !recordOverflow, records <= Int64(maximumActiveRecoveryRecords) else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeRecoveryRecords",
        maximum: maximumActiveRecoveryRecords
      )
    }
    guard !payloadOverflow, payloadBytes >= 0,
      payloadBytes <= Int64(maximumActiveRecoveryPayloadBytes)
    else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeRecoveryPayloadBytes",
        maximum: maximumActiveRecoveryPayloadBytes
      )
    }
  }

  static func requireOpenActionCapacity(in db: Database) throws {
    let count =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_supervision_actions
          WHERE state IN ('pending', 'ambiguous')
          """
      ) ?? 0
    guard count < maximumOpenActions else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "openActions",
        maximum: maximumOpenActions
      )
    }
  }

  static func fetchCurrentScope(taskID: TaskID, in db: Database) throws -> StoredScope? {
    guard
      let generation = try Int64.fetchOne(
        db,
        sql: "SELECT generation FROM bridge_supervision_current_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    else { return nil }
    return try fetchScope(taskID: taskID, generation: generation, in: db)
  }

  static func fetchScope(scope: DurableSupervisionScope, in db: Database) throws -> StoredScope? {
    guard
      let stored = try fetchScope(
        taskID: scope.taskID,
        generation: scope.generation,
        in: db
      )
    else { return nil }
    guard stored.scope == scope else {
      throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
    }
    return stored
  }

  static func fetchScope(taskID: TaskID, generation: Int64, in db: Database) throws
    -> StoredScope?
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM bridge_supervision_scopes WHERE task_id = ? AND generation = ?",
        arguments: [taskID.rawValue, generation]
      )
    else { return nil }
    return try decodeScope(row)
  }

  static func requireScope(_ scope: DurableSupervisionScope, in db: Database) throws {
    guard try fetchScope(scope: scope, in: db) != nil else {
      throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
    }
  }

  static func requireCurrentScope(
    _ scope: DurableSupervisionScope,
    in db: Database
  ) throws -> StoredScope {
    guard let current = try fetchCurrentScope(taskID: scope.taskID, in: db),
      current.scope == scope
    else { throw DurableSupervisionLedgerError.scopeConflict(scope.taskID) }
    return current
  }

  static func requireActiveCurrentScope(
    _ scope: DurableSupervisionScope,
    in db: Database
  ) throws -> StoredScope {
    let current = try requireCurrentScope(scope, in: db)
    guard current.status == .active else {
      throw DurableSupervisionLedgerError.scopeConflict(scope.taskID)
    }
    return current
  }

  static func fetchCheckpoint(
    scope: DurableSupervisionScope,
    sequence: UInt64,
    in db: Database
  ) throws -> StoredCheckpoint? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM bridge_supervision_checkpoints
          WHERE task_id = ? AND generation = ? AND checkpoint_sequence = ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation, Int64(sequence)]
      )
    else { return nil }
    return try decodeCheckpoint(row, scope: scope)
  }

  static func fetchReview(
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    in db: Database
  ) throws -> StoredReview? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM bridge_supervision_decisions
          WHERE task_id = ? AND generation = ? AND checkpoint_sequence = ? AND attempt = ?
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, Int64(position.checkpointSequence),
          Int(position.attempt),
        ]
      )
    else { return nil }
    return try decodeReview(row)
  }

  static func fetchReviewRows(
    scope: DurableSupervisionScope,
    after position: SupervisorReviewPosition?,
    limit: Int,
    in db: Database
  ) throws -> [Row] {
    guard let position else {
      return try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM bridge_supervision_decisions
          WHERE task_id = ? AND generation = ?
          ORDER BY checkpoint_sequence ASC, attempt ASC LIMIT ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation, limit]
      )
    }
    return try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM bridge_supervision_decisions
        WHERE task_id = ? AND generation = ?
          AND (checkpoint_sequence > ? OR (checkpoint_sequence = ? AND attempt > ?))
        ORDER BY checkpoint_sequence ASC, attempt ASC LIMIT ?
        """,
      arguments: [
        scope.taskID.rawValue, scope.generation, Int64(position.checkpointSequence),
        Int64(position.checkpointSequence), Int(position.attempt), limit,
      ]
    )
  }

  static func makeReviewRecord(
    _ stored: StoredReview,
    scope: DurableSupervisionScope,
    in db: Database
  ) throws -> DurableSupervisionReviewRecord {
    let action = try fetchAction(scope: scope, position: stored.position, in: db)
    return DurableSupervisionReviewRecord(
      scope: scope,
      position: stored.position,
      result: stored.result,
      state: stored.state,
      stateDigest: hexDigest(stored.statePayload),
      action: action,
      createdAt: stored.createdAt
    )
  }

  static func fetchAction(
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    in db: Database
  ) throws -> DurableSupervisorActionRecord? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM bridge_supervision_actions
          WHERE task_id = ? AND generation = ? AND checkpoint_sequence = ? AND attempt = ?
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, Int64(position.checkpointSequence),
          Int(position.attempt),
        ]
      )
    else { return nil }
    return try decodeAction(row, scope: scope)
  }

  static func fetchJoinedAction(id: String, in db: Database) throws
    -> DurableSupervisorActionRecord?
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT a.*, s.project_id, s.thread_id, s.turn_id
          FROM bridge_supervision_actions a
          JOIN bridge_supervision_scopes s
            ON s.task_id = a.task_id AND s.generation = a.generation
          WHERE a.action_id = ?
          """,
        arguments: [id]
      )
    else { return nil }
    return try decodeJoinedAction(row)
  }

  static func decodeScope(_ row: Row) throws -> StoredScope {
    guard let status = DurableSupervisionScopeStatus(rawValue: row["status"]) else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let scope = try DurableSupervisionScope(
      taskID: TaskID(rawValue: row["task_id"]),
      projectID: ProjectID(rawValue: row["project_id"]),
      threadID: ThreadID(rawValue: row["thread_id"]),
      turnID: TurnID(rawValue: row["turn_id"]),
      generation: row["generation"]
    )
    let configurationPayload: Data = row["configuration_json"]
    let configurationDigest: Data = row["configuration_sha256"]
    let statePayload: Data = row["reducer_state_json"]
    let stateDigest: Data = row["reducer_state_sha256"]
    guard digest(configurationPayload) == configurationDigest,
      digest(statePayload) == stateDigest
    else { throw DurableSupervisionLedgerError.corruptRecord }
    let configuration: SupervisorGuardConfiguration = try decodeCanonical(configurationPayload)
    let state: SupervisorGuardState = try decodeCanonical(statePayload)
    let dates = try decodeDates(created: row["created_at"], updated: row["updated_at"])
    return StoredScope(
      record: makeStateRecord(
        scope: scope,
        status: status,
        configuration: configuration,
        state: state,
        statePayload: statePayload,
        createdAt: dates.created,
        updatedAt: dates.updated
      ),
      configurationPayload: configurationPayload,
      statePayload: statePayload
    )
  }

  static func decodeCheckpoint(_ row: Row, scope: DurableSupervisionScope) throws
    -> StoredCheckpoint
  {
    let payload: Data = row["checkpoint_json"]
    let checksum: Data = row["checkpoint_sha256"]
    guard digest(payload) == checksum else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let checkpoint: SupervisorCheckpoint = try decodeCanonical(payload)
    let sequence: Int64 = row["checkpoint_sequence"]
    guard sequence > 0, UInt64(sequence) == checkpoint.sequence else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    try validate(checkpoint: checkpoint, scope: scope)
    let timestamp = try decodeDate(row["created_at"])
    return StoredCheckpoint(
      record: makeCheckpointRecord(
        scope: scope,
        checkpoint: checkpoint,
        payload: payload,
        createdAt: timestamp
      ),
      payload: payload
    )
  }

  static func decodeReview(_ row: Row) throws -> StoredReview {
    let resultPayload: Data = row["result_json"]
    let resultChecksum: Data = row["result_sha256"]
    let statePayload: Data = row["reducer_state_json"]
    let stateChecksum: Data = row["reducer_state_sha256"]
    guard digest(resultPayload) == resultChecksum, digest(statePayload) == stateChecksum else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let sequence: Int64 = row["checkpoint_sequence"]
    let attempt: Int = row["attempt"]
    guard sequence > 0, let exactAttempt = UInt16(exactly: attempt) else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    return StoredReview(
      position: SupervisorReviewPosition(
        checkpointSequence: UInt64(sequence),
        attempt: exactAttempt
      ),
      result: try decodeCanonical(resultPayload),
      resultPayload: resultPayload,
      state: try decodeCanonical(statePayload),
      statePayload: statePayload,
      createdAt: try decodeDate(row["created_at"])
    )
  }

  static func decodeJoinedAction(_ row: Row) throws -> DurableSupervisorActionRecord {
    let scope = try DurableSupervisionScope(
      taskID: TaskID(rawValue: row["task_id"]),
      projectID: ProjectID(rawValue: row["project_id"]),
      threadID: ThreadID(rawValue: row["thread_id"]),
      turnID: TurnID(rawValue: row["turn_id"]),
      generation: row["generation"]
    )
    return try decodeAction(row, scope: scope)
  }

  static func decodeAction(_ row: Row, scope: DurableSupervisionScope) throws
    -> DurableSupervisorActionRecord
  {
    let id: String = row["action_id"]
    try validateActionID(id)
    guard let kind = DurableSupervisorActionKind(rawValue: row["kind"]),
      let state = DurableSupervisorActionState(rawValue: row["state"])
    else { throw DurableSupervisionLedgerError.corruptRecord }
    let instruction: String = row["instruction"]
    let instructionChecksum: Data = row["instruction_sha256"]
    try validateInstruction(instruction)
    guard digest(Data(instruction.utf8)) == instructionChecksum else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let sequence: Int64 = row["checkpoint_sequence"]
    let attempt: Int = row["attempt"]
    guard sequence > 0, let exactAttempt = UInt16(exactly: attempt) else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let dates = try decodeDates(created: row["created_at"], updated: row["updated_at"])
    return DurableSupervisorActionRecord(
      id: id,
      scope: scope,
      position: SupervisorReviewPosition(
        checkpointSequence: UInt64(sequence),
        attempt: exactAttempt
      ),
      kind: kind,
      instruction: instruction,
      state: state,
      createdAt: dates.created,
      updatedAt: dates.updated
    )
  }

  static func makeStateRecord(
    scope: DurableSupervisionScope,
    status: DurableSupervisionScopeStatus,
    configuration: SupervisorGuardConfiguration,
    state: SupervisorGuardState,
    statePayload: Data,
    createdAt: Date,
    updatedAt: Date
  ) -> DurableSupervisionStateRecord {
    return DurableSupervisionStateRecord(
      scope: scope,
      status: status,
      configuration: configuration,
      state: state,
      stateDigest: hexDigest(statePayload),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  static func actionID(
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    kind: DurableSupervisorActionKind,
    instruction: String
  ) throws -> String {
    let seed = ActionSeed(
      taskID: scope.taskID.rawValue,
      generation: scope.generation,
      checkpointSequence: position.checkpointSequence,
      attempt: position.attempt,
      kind: kind,
      instruction: instruction
    )
    return "act_\(hexDigest(try canonicalJSON(seed)))"
  }

  static func makeCheckpointRecord(
    scope: DurableSupervisionScope,
    checkpoint: SupervisorCheckpoint,
    payload: Data,
    createdAt: Date
  ) -> DurableSupervisorCheckpointRecord {
    DurableSupervisorCheckpointRecord(
      scope: scope,
      checkpoint: checkpoint,
      checkpointDigest: hexDigest(payload),
      createdAt: createdAt
    )
  }

  static func makeEvidenceSummary(scope: StoredScope, in db: Database) throws
    -> DurableSupervisionEvidenceSummary
  {
    let arguments: StatementArguments = [scope.scope.taskID.rawValue, scope.scope.generation]
    let checkpointCount =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_supervision_checkpoints
          WHERE task_id = ? AND generation = ?
          """,
        arguments: arguments
      ) ?? 0
    let reviewCount =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_supervision_decisions
          WHERE task_id = ? AND generation = ?
          """,
        arguments: arguments
      ) ?? 0
    let appliedSteerCount =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_supervision_actions
          WHERE task_id = ? AND generation = ? AND kind = 'steer' AND state = 'applied'
          """,
        arguments: arguments
      ) ?? 0
    let latest = try Row.fetchOne(
      db,
      sql: """
        SELECT result_json, result_sha256 FROM bridge_supervision_decisions
        WHERE task_id = ? AND generation = ?
        ORDER BY checkpoint_sequence DESC, attempt DESC LIMIT 1
        """,
      arguments: arguments
    )
    let decision = try latestDecision(latest)
    return DurableSupervisionEvidenceSummary(
      scope: scope.scope,
      checkpointCount: checkpointCount,
      reviewCount: reviewCount,
      appliedSteerCount: appliedSteerCount,
      latestDecision: decision?.kind,
      latestDecisionDigest: decision?.digest,
      reducerStateDigest: scope.record.stateDigest
    )
  }

  static func latestDecision(_ row: Row?) throws
    -> (kind: SupervisorDecisionKind, digest: String)?
  {
    guard let row else { return nil }
    let payload: Data = row["result_json"]
    let checksum: Data = row["result_sha256"]
    guard digest(payload) == checksum else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let result: DurableSupervisorReviewResult = try decodeCanonical(payload)
    guard case .decision(let decision) = result else { return nil }
    return (decision.decision, hexDigest(try canonicalJSON(decision)))
  }

  static func validate(checkpoint: SupervisorCheckpoint, scope: DurableSupervisionScope) throws {
    guard checkpoint.sequence > 0, checkpoint.sequence <= UInt64(Int64.max),
      checkpoint.taskID == scope.taskID.rawValue,
      checkpoint.turnID == scope.turnID.rawValue
    else { throw DurableSupervisionLedgerError.invalidArgument("checkpoint") }
  }

  static func validate(limit: Int) throws {
    guard (1...maximumQueryLimit).contains(limit) else {
      throw DurableSupervisionLedgerError.invalidArgument("limit")
    }
  }

  static func validate(date: Date, field: String) throws {
    guard date.timeIntervalSince1970.isFinite else {
      throw DurableSupervisionLedgerError.invalidArgument(field)
    }
  }

  static func normalized(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970)
  }

  static func validateActionID(_ id: String) throws {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
    guard !id.isEmpty, id.utf8.count <= 80, id.allSatisfy(allowed.contains) else {
      throw DurableSupervisionLedgerError.invalidArgument("actionID")
    }
  }

  static func validateInstruction(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 4_096, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil
    else { throw DurableSupervisionLedgerError.invalidArgument("instruction") }
  }

  static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try canonicalize(encoder.encode(value))
    } catch let error as DurableSupervisionLedgerError {
      throw error
    } catch {
      throw DurableSupervisionLedgerError.invalidArgument("payload")
    }
  }

  static func decodeCanonical<Value: Decodable>(_ data: Data) throws -> Value {
    guard data.count <= SupervisorCheckpoint.maximumEncodedBytes,
      (try? canonicalize(data)) == data
    else { throw DurableSupervisionLedgerError.corruptRecord }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw DurableSupervisionLedgerError.corruptRecord
    }
  }

  static func canonicalize(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw DurableSupervisionLedgerError.invalidArgument("payload")
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  static func hexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func decodeDate(_ value: Double) throws -> Date {
    guard value.isFinite else { throw DurableSupervisionLedgerError.corruptRecord }
    return Date(timeIntervalSince1970: value)
  }

  static func decodeDates(created: Double, updated: Double) throws
    -> (created: Date, updated: Date)
  {
    (try decodeDate(created), try decodeDate(updated))
  }
}
