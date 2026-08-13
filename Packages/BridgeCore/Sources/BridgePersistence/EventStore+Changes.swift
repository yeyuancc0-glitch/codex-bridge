import BridgeDomain
import Foundation
import GRDB

extension EventStore {
  public func taskChangeHead() throws -> Int64 {
    try database.read { db in
      try Self.taskChangeHead(in: db)
    }
  }

  public func changes(after changeID: Int64 = 0, limit: Int) throws -> [TaskChange] {
    guard changeID >= 0 else { throw EventStoreError.invalidArgument("changeID") }
    guard (1...500).contains(limit) else { throw EventStoreError.invalidArgument("limit") }
    return try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT change_id, task_id, event_seq, kind, created_at
          FROM task_change_log
          WHERE change_id > ?
          ORDER BY change_id
          LIMIT ?
          """,
        arguments: [changeID, limit]
      )
      return try rows.map(Self.decodeChange)
    }
  }

  public func taskIDsWithActiveSnapshots(
    afterTaskID: TaskID? = nil,
    limit: Int
  ) throws -> [TaskID] {
    guard (1...500).contains(limit) else { throw EventStoreError.invalidArgument("limit") }
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT snapshots.task_id
          FROM task_state_snapshots AS snapshots
          JOIN tasks ON tasks.task_id = snapshots.task_id
          WHERE snapshots.task_id > ?
            AND snapshots.recovery_required = 1
            AND snapshots.last_event_seq = tasks.last_event_seq
          ORDER BY snapshots.task_id
          LIMIT ?
          """,
        arguments: [afterTaskID?.rawValue ?? "", limit]
      ).map(TaskID.init(rawValue:))
    }
  }

  static func decodeChange(_ row: Row) throws -> TaskChange {
    let changeID: Int64 = row["change_id"]
    let taskID = TaskID(rawValue: row["task_id"])
    let eventSequence: Int64 = row["event_seq"]
    let kind: String = row["kind"]
    let timestamp: Double = row["created_at"]
    guard changeID > 0,
      eventSequence > 0,
      timestamp.isFinite,
      validStoredIdentifier(taskID.rawValue, maximumBytes: 1_024),
      validStoredIdentifier(kind, maximumBytes: 1_024)
    else {
      throw EventStoreError.corruptEvent(taskID: taskID, sequence: eventSequence)
    }
    return TaskChange(
      changeID: changeID,
      taskID: taskID,
      eventSequence: eventSequence,
      kind: kind,
      createdAt: Date(timeIntervalSince1970: timestamp)
    )
  }

  static func taskChangeHead(in db: Database) throws -> Int64 {
    guard
      let head = try Int64.fetchOne(
        db,
        sql: """
          SELECT head_change_id
          FROM task_change_state
          WHERE singleton_id = 1
          """
      ), head >= 0
    else { throw EventStoreError.invalidArgument("taskChangeHead") }
    return head
  }

  static func validStoredIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return false
    }
    return !value.hasPrefix("/") && !value.hasPrefix("~/") && !value.hasPrefix("file://")
  }
}
