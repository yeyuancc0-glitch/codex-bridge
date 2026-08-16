import BridgeDomain
import BridgeSupervisor
import Foundation
import GRDB

extension DurableSupervisionLedger {
  private static let recoveryPageSize = 32

  static func validateActiveRecords(in database: DatabaseQueue) throws {
    do {
      try database.read { db in
        try validateActiveRecoveryBudget(in: db)
        try validateActiveScopes(in: db)
        try validateOpenActions(in: db)
      }
    } catch let error as DurableSupervisionLedgerError {
      throw error
    } catch {
      throw DurableSupervisionLedgerError.corruptRecord
    }
  }

  static func validateActiveRecoveryBudget(in db: Database) throws {
    let budget = try activeRecoveryBudget(in: db)
    guard budget.records <= Int64(maximumActiveRecoveryRecords) else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeRecoveryRecords",
        maximum: maximumActiveRecoveryRecords
      )
    }
    guard budget.payloadBytes <= Int64(maximumActiveRecoveryPayloadBytes) else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeRecoveryPayloadBytes",
        maximum: maximumActiveRecoveryPayloadBytes
      )
    }
  }

  static func validateActiveScopes(in db: Database) throws {
    var cursor: String?
    var count = 0
    while true {
      let rows = try activeScopeKeyRows(after: cursor, in: db)
      guard !rows.isEmpty else { return }
      for row in rows {
        let taskID = TaskID(rawValue: row["task_id"])
        let generation: Int64 = row["generation"]
        guard let scope = try fetchScope(taskID: taskID, generation: generation, in: db),
          scope.status == .active
        else { throw DurableSupervisionLedgerError.corruptRecord }
        try validateHistory(for: scope, in: db)
        count += 1
        guard count <= maximumActiveScopes else {
          throw DurableSupervisionLedgerError.limitExceeded(
            field: "activeScopes",
            maximum: maximumActiveScopes
          )
        }
      }
      cursor = rows.last?["task_id"]
    }
  }

  static func activeScopeKeyRows(after cursor: String?, in db: Database) throws -> [Row] {
    guard let cursor else {
      return try Row.fetchAll(
        db,
        sql: """
          SELECT s.task_id, s.generation
          FROM bridge_supervision_current_scopes c
          JOIN bridge_supervision_scopes s
            ON s.task_id = c.task_id AND s.generation = c.generation
          WHERE s.status = 'active'
          ORDER BY s.task_id ASC LIMIT ?
          """,
        arguments: [recoveryPageSize]
      )
    }
    return try Row.fetchAll(
      db,
      sql: """
        SELECT s.task_id, s.generation
        FROM bridge_supervision_current_scopes c
        JOIN bridge_supervision_scopes s
          ON s.task_id = c.task_id AND s.generation = c.generation
        WHERE s.status = 'active' AND s.task_id > ?
        ORDER BY s.task_id ASC LIMIT ?
        """,
      arguments: [cursor, recoveryPageSize]
    )
  }

  static func validateHistory(for scopeRecord: StoredScope, in db: Database) throws {
    try validateCheckpoints(for: scopeRecord.scope, in: db)
    try replayReviews(for: scopeRecord, in: db)
  }

  static func validateCheckpoints(for scope: DurableSupervisionScope, in db: Database) throws {
    var cursor: Int64 = 0
    var count = 0
    while true {
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM bridge_supervision_checkpoints
          WHERE task_id = ? AND generation = ? AND checkpoint_sequence > ?
          ORDER BY checkpoint_sequence ASC LIMIT ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation, cursor, recoveryPageSize]
      )
      guard !rows.isEmpty else { return }
      for row in rows {
        let checkpoint = try decodeCheckpoint(row, scope: scope).record.checkpoint
        guard Int64(checkpoint.sequence) > cursor else {
          throw DurableSupervisionLedgerError.corruptRecord
        }
        cursor = Int64(checkpoint.sequence)
        count += 1
        guard count <= maximumCheckpointsPerActiveScope else {
          throw DurableSupervisionLedgerError.limitExceeded(
            field: "activeCheckpoints",
            maximum: maximumCheckpointsPerActiveScope
          )
        }
      }
    }
  }

  static func replayReviews(for scopeRecord: StoredScope, in db: Database) throws {
    var reducer = SupervisorReducer(configuration: scopeRecord.configuration)
    var cursor: SupervisorReviewPosition?
    var reviewCount = 0
    var expectedActionCount = 0
    while true {
      let rows = try fetchReviewRows(
        scope: scopeRecord.scope,
        after: cursor,
        limit: recoveryPageSize,
        in: db
      )
      guard !rows.isEmpty else { break }
      for row in rows {
        let review = try decodeReview(row)
        guard cursor.map({ $0 < review.position }) ?? true,
          let checkpoint = try fetchCheckpoint(
            scope: scopeRecord.scope,
            sequence: review.position.checkpointSequence,
            in: db
          )
        else { throw DurableSupervisionLedgerError.corruptRecord }
        try replay(
          review,
          checkpoint: checkpoint.record.checkpoint,
          scope: scopeRecord.scope,
          reducer: &reducer,
          expectedActionCount: &expectedActionCount,
          in: db
        )
        cursor = review.position
        reviewCount += 1
        guard reviewCount <= maximumReviewsPerActiveScope else {
          throw DurableSupervisionLedgerError.limitExceeded(
            field: "activeReviews",
            maximum: maximumReviewsPerActiveScope
          )
        }
      }
    }
    let actionCount = try scopedActionCount(scope: scopeRecord.scope, in: db)
    guard actionCount <= maximumActionsPerActiveScope else {
      throw DurableSupervisionLedgerError.limitExceeded(
        field: "activeActions",
        maximum: maximumActionsPerActiveScope
      )
    }
    guard reducer.state == scopeRecord.state,
      (try canonicalJSON(reducer.state)) == scopeRecord.statePayload,
      actionCount == expectedActionCount
    else { throw DurableSupervisionLedgerError.corruptRecord }
  }

  static func replay(
    _ review: StoredReview,
    checkpoint: SupervisorCheckpoint,
    scope: DurableSupervisionScope,
    reducer: inout SupervisorReducer,
    expectedActionCount: inout Int,
    in db: Database
  ) throws {
    try validate(result: review.result, checkpoint: checkpoint)
    let reducerAction = reducer.apply(
      outcome(review.result, position: review.position, checkpoint: checkpoint)
    )
    let statePayload = try canonicalJSON(reducer.state)
    guard reducer.state == review.state, statePayload == review.statePayload else {
      throw DurableSupervisionLedgerError.corruptRecord
    }
    let storedAction = try fetchAction(scope: scope, position: review.position, in: db)
    try validateAction(
      reducerAction,
      scope: scope,
      position: review.position,
      stored: storedAction
    )
    if storedAction != nil { expectedActionCount += 1 }
  }

  static func scopedActionCount(scope: DurableSupervisionScope, in db: Database) throws -> Int {
    try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM bridge_supervision_actions
        WHERE task_id = ? AND generation = ?
        """,
      arguments: [scope.taskID.rawValue, scope.generation]
    ) ?? 0
  }

  static func validateAction(
    _ reducerAction: SupervisorAction,
    scope: DurableSupervisionScope,
    position: SupervisorReviewPosition,
    stored: DurableSupervisorActionRecord?
  ) throws {
    guard let expected = durableAction(reducerAction) else {
      guard stored == nil else { throw DurableSupervisionLedgerError.corruptRecord }
      return
    }
    guard let stored,
      stored.kind == expected.kind,
      stored.instruction == expected.instruction,
      stored.taskEventSequence > 0,
      stored.id
        == (try actionID(
          scope: scope,
          position: position,
          kind: expected.kind,
          instruction: expected.instruction
        ))
    else { throw DurableSupervisionLedgerError.corruptRecord }
  }

  static func validateOpenActions(in db: Database) throws {
    var cursor: String?
    var count = 0
    while true {
      let rows = try openActionRows(after: cursor, in: db)
      guard !rows.isEmpty else { return }
      for row in rows {
        let action = try decodeJoinedAction(row)
        let status: String = row["scope_status"]
        let currentGeneration: Int64? = row["current_generation"]
        guard status == DurableSupervisionScopeStatus.active.rawValue,
          currentGeneration == action.scope.generation
        else { throw DurableSupervisionLedgerError.corruptRecord }
        cursor = action.id
        count += 1
        guard count <= maximumOpenActions else {
          throw DurableSupervisionLedgerError.limitExceeded(
            field: "openActions",
            maximum: maximumOpenActions
          )
        }
      }
    }
  }

  static func openActionRows(after cursor: String?, in db: Database) throws -> [Row] {
    let cursorClause = cursor == nil ? "" : "AND a.action_id > ?"
    var arguments: StatementArguments = []
    if let cursor { arguments += [cursor] }
    arguments += [recoveryPageSize]
    return try Row.fetchAll(
      db,
      sql: """
        SELECT a.*, s.project_id, s.thread_id, s.turn_id, s.status AS scope_status,
               c.generation AS current_generation
        FROM bridge_supervision_actions a
        JOIN bridge_supervision_scopes s
          ON s.task_id = a.task_id AND s.generation = a.generation
        LEFT JOIN bridge_supervision_current_scopes c ON c.task_id = a.task_id
        WHERE a.state IN ('pending', 'ambiguous') \(cursorClause)
        ORDER BY a.action_id ASC LIMIT ?
        """,
      arguments: arguments
    )
  }
}
