import GRDB

extension EventStore {
  public func pruneNotificationHistory(limit: Int = 500) throws -> TaskNotificationPruneResult {
    guard (1...500).contains(limit) else { throw EventStoreError.invalidArgument("limit") }
    return try database.write { db in
      let scheduledDeleted = try Self.pruneScheduledReservations(limit: limit, in: db)
      let remaining = limit - scheduledDeleted
      let changesDeleted = try Self.pruneConsumedChanges(limit: remaining, in: db)
      return TaskNotificationPruneResult(
        scheduledReservationsDeleted: scheduledDeleted,
        changesDeleted: changesDeleted
      )
    }
  }

  private static func pruneScheduledReservations(limit: Int, in db: Database) throws -> Int {
    guard limit > 0 else { return 0 }
    try db.execute(
      sql: """
        DELETE FROM task_notification_ledger
        WHERE rowid IN (
          SELECT ledger.rowid
          FROM task_notification_ledger AS ledger
          JOIN task_notification_consumers AS consumer
            ON consumer.consumer_id = ledger.consumer_id
          WHERE ledger.state = 'scheduled'
            AND ledger.change_id <= consumer.change_cursor
          ORDER BY ledger.change_id, ledger.consumer_id, ledger.stable_key
          LIMIT ?
        )
        """,
      arguments: [limit]
    )
    return db.changesCount
  }

  private static func pruneConsumedChanges(limit: Int, in db: Database) throws -> Int {
    guard limit > 0 else { return 0 }
    guard
      let consumedThrough = try Int64.fetchOne(
        db,
        sql: "SELECT MIN(change_cursor) FROM task_notification_consumers"
      )
    else { return 0 }
    try db.execute(
      sql: """
        DELETE FROM task_change_log
        WHERE change_id IN (
          SELECT change.change_id
          FROM task_change_log AS change
          WHERE change.change_id <= ?
            AND NOT EXISTS (
              SELECT 1
              FROM task_notification_ledger AS ledger
              WHERE ledger.change_id = change.change_id
            )
          ORDER BY change.change_id
          LIMIT ?
        )
        """,
      arguments: [consumedThrough, limit]
    )
    return db.changesCount
  }
}
