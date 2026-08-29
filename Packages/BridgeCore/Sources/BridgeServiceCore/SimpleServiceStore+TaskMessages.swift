import BridgeDomain
import GRDB

extension SimpleServiceStore {
  @discardableResult
  public func upsertTaskMessage(
    _ message: ServiceTaskMessageDraft,
    taskID: TaskID
  ) throws -> ServiceTaskMessageRecord {
    do {
      return try database.write { db in
        guard try Self.taskRow(id: taskID, in: db) != nil else {
          throw ServiceStoreError.unknownTask(taskID)
        }
        try Self.upsertTaskMessage(message, taskID: taskID, in: db)
        try db.execute(
          sql: """
            UPDATE bridge_service_tasks
            SET updated_at = MAX(updated_at, ?)
            WHERE task_id = ?
            """,
          arguments: [message.updatedAt.timeIntervalSince1970, taskID.rawValue]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
        guard let row = try Self.taskMessageRow(taskID: taskID, key: message.key, in: db) else {
          throw ServiceStoreError.corruptRecord
        }
        return try Self.decodeTaskMessage(row)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func taskMessages(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) throws -> [ServiceTaskMessageRecord] {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("taskMessages.limit")
    }
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT * FROM bridge_service_task_messages
              WHERE task_id = ?
                AND (? IS NULL OR message_id < ?)
              ORDER BY message_id DESC
              LIMIT ?
            )
            ORDER BY message_id ASC
            """,
          arguments: [taskID.rawValue, beforeMessageID, beforeMessageID, limit]
        )
        return try rows.map(Self.decodeTaskMessage)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func recentTaskMessageActivity(
    taskID: TaskID,
    limit: Int = 12
  ) throws -> [ServiceTaskMessageRecord] {
    guard (1...100).contains(limit) else {
      throw ServiceStoreError.invalidArgument("taskMessageActivity.limit")
    }
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT * FROM bridge_service_task_messages
              WHERE task_id = ? AND role = 'agent'
              ORDER BY updated_at DESC, message_id DESC
              LIMIT ?
            )
            ORDER BY updated_at ASC, message_id ASC
            """,
          arguments: [taskID.rawValue, limit]
        )
        return try rows.map(Self.decodeTaskMessage)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

}
