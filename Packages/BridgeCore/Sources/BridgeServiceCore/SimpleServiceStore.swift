import BridgeDomain
import Foundation
import GRDB

public actor SimpleServiceStore {
  let database: DatabaseQueue
  let encoder = JSONEncoder()

  public init(path: String) throws {
    guard !path.isEmpty else { throw ServiceStoreError.invalidArgument("path") }
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    do {
      let openedDatabase = try DatabaseQueue(path: path, configuration: configuration)
      try ServiceStoreSchema.prepare(openedDatabase)
      database = openedDatabase
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public static func inMemory() throws -> SimpleServiceStore {
    try SimpleServiceStore(path: ":memory:")
  }

  public func insertProject(_ project: ServiceProjectRecord) throws {
    do {
      try database.write { db in
        if try Self.projectRow(id: project.id, in: db) != nil {
          throw ServiceStoreError.duplicateProject(project.id)
        }
        if try Self.projectRow(root: project.root, in: db) != nil {
          throw ServiceStoreError.duplicateProjectRoot(project.root.canonicalPath)
        }
        try Self.insert(project, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      if (try? database.read({ try Self.projectRow(id: project.id, in: $0) })) != nil {
        throw ServiceStoreError.duplicateProject(project.id)
      }
      if (try? database.read({ try Self.projectRow(root: project.root, in: $0) })) != nil {
        throw ServiceStoreError.duplicateProjectRoot(project.root.canonicalPath)
      }
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateProject(_ project: ServiceProjectRecord) throws {
    let workspaceCommands = try encoder.encode(project.workspaceCommands)
    let commandBlacklist = try encoder.encode(project.commandBlacklist)
    guard workspaceCommands.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    do {
      try database.write { db in
        guard let row = try Self.projectRow(id: project.id, in: db) else {
          throw ServiceStoreError.unknownProject(project.id)
        }
        let existing = try Self.decodeProject(row)
        guard existing.root == project.root,
          existing.createdAt == project.createdAt,
          project.updatedAt >= existing.updatedAt
        else {
          throw ServiceStoreError.invalidArgument("project.update")
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET name = ?, read_permission = ?, write_permission = ?,
                network_permission = ?, direct_command_mode = ?,
                workspace_commands_json = ?,
                direct_blacklist_json = ?, updated_at = ?
            WHERE project_id = ?
            """,
          arguments: [
            project.name,
            project.accessPolicy.read.rawValue,
            project.accessPolicy.write.rawValue,
            project.accessPolicy.network.rawValue,
            project.directCommandMode.rawValue,
            workspaceCommands,
            commandBlacklist,
            project.updatedAt.timeIntervalSince1970,
            project.id.rawValue,
          ]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateWorkspaceConfiguration(
    projectID: ProjectID,
    directCommandMode: ServiceDirectCommandMode,
    workspaceCommands: [ServiceWorkspaceCommand],
    commandBlacklist: [ServiceCommandBlacklistRule],
    at date: Date
  ) throws {
    try ServiceValidation.date(date, field: "project.updatedAt")
    guard workspaceCommands.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    let workspaceCommandsData = try encoder.encode(workspaceCommands)
    let commandBlacklistData = try encoder.encode(commandBlacklist)
    guard workspaceCommandsData.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklistData.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    do {
      try database.write { db in
        guard let row = try Self.projectRow(id: projectID, in: db) else {
          throw ServiceStoreError.unknownProject(projectID)
        }
        let existing = try Self.decodeProject(row)
        guard date >= existing.updatedAt else {
          throw ServiceStoreError.invalidArgument("project.updatedAt")
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET direct_command_mode = ?, workspace_commands_json = ?,
                direct_blacklist_json = ?, updated_at = ?
            WHERE project_id = ?
            """,
          arguments: [
            directCommandMode.rawValue,
            workspaceCommandsData,
            commandBlacklistData,
            date.timeIntervalSince1970,
            projectID.rawValue,
          ]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func removeProject(id: ProjectID) throws {
    do {
      try database.write { db in
        try db.execute(
          sql: "DELETE FROM bridge_service_projects WHERE project_id = ?",
          arguments: [id.rawValue]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.unknownProject(id) }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func project(id: ProjectID) throws -> ServiceProjectRecord? {
    do {
      return try database.read { db in
        try Self.projectRow(id: id, in: db).map(Self.decodeProject)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func projects() throws -> [ServiceProjectRecord] {
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_projects
            ORDER BY name COLLATE NOCASE, project_id
            """
        ).map(Self.decodeProject)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func setSetting(_ setting: ServiceSettingRecord) throws {
    try setSettings([setting])
  }

  func setSettings(_ settings: [ServiceSettingRecord]) throws {
    do {
      try database.write { db in
        for setting in settings {
          try db.execute(
            sql: """
              INSERT INTO bridge_service_settings (setting_key, setting_value, updated_at)
              VALUES (?, ?, ?)
              ON CONFLICT(setting_key) DO UPDATE SET
                setting_value = excluded.setting_value,
                updated_at = excluded.updated_at
              """,
            arguments: [setting.key, setting.value, setting.updatedAt.timeIntervalSince1970]
          )
        }
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func setting(key: String) throws -> ServiceSettingRecord? {
    try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
          arguments: [key]
        ).map(Self.decodeSetting)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

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
    event: ServiceTaskEventDraft
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

  @discardableResult
  public func markIncompleteTasksUnknown(at date: Date) throws -> [ServiceTaskRecord] {
    try ServiceValidation.date(date, field: "recovery.date")
    do {
      return try database.write { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE status IN ('starting', 'running', 'waiting_for_codex_approval')
            ORDER BY created_at, task_id
            """
        )
        var updated: [ServiceTaskRecord] = []
        updated.reserveCapacity(rows.count)
        for row in rows {
          let task = try Self.decodeTask(row)
          let supervisorStatus: ServiceSupervisorStatus =
            task.state.supervisorStatus == .disabled ? .disabled : .degraded
          let state = try ServiceTaskState(
            codexThreadID: task.state.codexThreadID,
            codexTurnID: task.state.codexTurnID,
            status: .unknown,
            supervisorStatus: supervisorStatus,
            currentStep: task.state.currentStep,
            changedFiles: task.state.changedFiles,
            resultSummary: task.state.resultSummary,
            supervisorSummary: task.state.supervisorSummary,
            failureCode: task.state.failureCode
          )
          let recovered = try task.replacingState(state, updatedAt: date)
          try Self.validateTransition(from: task.state.status, to: .unknown)
          try updateTaskRow(recovered, in: db)
          try Self.insert(
            ServiceTaskEventDraft(
              kind: .taskMarkedUnknown,
              summary: "The service restarted without an attached Codex turn.",
              createdAt: date
            ),
            taskID: task.id,
            in: db
          )
          updated.append(recovered)
        }
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
