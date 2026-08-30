import BridgeDomain
import GRDB

extension SimpleServiceStore {
  public func createTask(
    _ task: ServiceTaskRecord,
    event: ServiceTaskEventDraft
  ) throws -> ServiceTaskCreationResult {
    guard event.kind == .taskCreated,
      event.createdAt == task.updatedAt,
      task.createdAt == task.updatedAt
    else {
      throw ServiceStoreError.invalidArgument("task.creationEvent")
    }
    do {
      return try database.write { db in
        guard try Self.projectRow(id: task.projectID, in: db) != nil else {
          throw ServiceStoreError.unknownProject(task.projectID)
        }
        if let existing = try Self.idempotentTask(for: task, in: db) {
          return try Self.reusedResult(existing: existing, requested: task)
        }
        if let row = try Self.taskRow(id: task.id, in: db) {
          return try Self.reusedResult(existing: Self.decodeTask(row), requested: task)
        }
        if task.permissionMode == .workspaceWrite, task.state.status.holdsWriteSlot,
          try Self.activeWriteTaskRow(projectID: task.projectID, in: db) != nil
        {
          throw ServiceStoreError.activeWriteTaskExists(task.projectID)
        }
        try insertTask(task, in: db)
        try Self.insert(event, taskID: task.id, in: db)
        return ServiceTaskCreationResult(task: task, reusedExistingTask: false)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      if let existing = try? existingIdempotentTask(for: task) {
        return try Self.reusedResult(existing: existing, requested: task)
      }
      if let existing = try? self.task(id: task.id) {
        return try Self.reusedResult(existing: existing, requested: task)
      }
      if task.permissionMode == .workspaceWrite,
        (try? activeWriteTask(projectID: task.projectID)) != nil
      {
        throw ServiceStoreError.activeWriteTaskExists(task.projectID)
      }
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateTask(
    _ task: ServiceTaskRecord,
    event: ServiceTaskEventDraft,
    expectedStatus: ServiceTaskStatus? = nil
  ) throws {
    guard event.createdAt == task.updatedAt else {
      throw ServiceStoreError.invalidArgument("task.updateEvent")
    }
    do {
      try database.write { db in
        guard let row = try Self.taskRow(id: task.id, in: db) else {
          throw ServiceStoreError.unknownTask(task.id)
        }
        let existing = try Self.decodeTask(row)
        guard task.hasSameImmutableFields(as: existing) else {
          throw ServiceStoreError.immutableTaskChanged(task.id)
        }
        guard task.updatedAt >= existing.updatedAt else {
          throw ServiceStoreError.invalidArgument("task.updatedAt")
        }
        if let expectedStatus, existing.state.status != expectedStatus {
          throw ServiceStoreError.invalidTaskTransition(
            from: existing.state.status,
            to: task.state.status
          )
        }
        try Self.validateTransition(from: existing.state.status, to: task.state.status)
        try updateTaskRow(task, in: db)
        try Self.insert(event, taskID: task.id, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func task(id: TaskID) throws -> ServiceTaskRecord? {
    do {
      return try database.read { db in
        try Self.taskRow(id: id, in: db).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func task(
    providerSessionID: String,
    providerID: String,
    installationID: String,
    projectID: ProjectID
  ) throws -> ServiceTaskRecord? {
    try ServiceValidation.identifier(
      providerSessionID,
      field: "task.providerSessionID",
      maximumBytes: 1_024
    )
    try ServiceValidation.identifier(providerID, field: "task.providerID", maximumBytes: 64)
    try ServiceValidation.identifier(
      installationID,
      field: "task.installationID",
      maximumBytes: 256
    )
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE project_id = ?
              AND provider_id = ?
              AND installation_id = ?
              AND (provider_session_id = ? OR requested_thread_id = ?)
            ORDER BY updated_at DESC, task_id
            LIMIT 1
            """,
          arguments: [
            projectID.rawValue, providerID, installationID, providerSessionID,
            providerSessionID,
          ]
        ).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func tasks(projectID: ProjectID? = nil, limit: Int = 100) throws
    -> [ServiceTaskRecord]
  {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("tasks.limit")
    }
    do {
      return try database.read { db in
        let rows: [Row]
        if let projectID {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_tasks
              WHERE project_id = ?
              ORDER BY updated_at DESC, task_id
              LIMIT ?
              """,
            arguments: [projectID.rawValue, limit]
          )
        } else {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_tasks
              ORDER BY updated_at DESC, task_id
              LIMIT ?
              """,
            arguments: [limit]
          )
        }
        return try rows.map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func events(taskID: TaskID, limit: Int = 100) throws -> [ServiceTaskEventRecord] {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("taskEvents.limit")
    }
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT * FROM bridge_service_task_events
              WHERE task_id = ?
              ORDER BY event_id DESC
              LIMIT ?
            )
            ORDER BY event_id ASC
            """,
          arguments: [taskID.rawValue, limit]
        )
        return try rows.map(Self.decodeEvent)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func activeWriteTask(projectID: ProjectID) throws -> ServiceTaskRecord? {
    do {
      return try database.read { db in
        try Self.activeWriteTaskRow(projectID: projectID, in: db).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func removeTask(id: TaskID) throws {
    do {
      try database.write { db in
        guard try Self.taskRow(id: id, in: db) != nil else {
          throw ServiceStoreError.unknownTask(id)
        }
        try db.execute(
          sql: "DELETE FROM bridge_service_tasks WHERE task_id = ?",
          arguments: [id.rawValue]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
