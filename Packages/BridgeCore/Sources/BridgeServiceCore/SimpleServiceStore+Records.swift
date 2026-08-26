import BridgeDomain
import BridgeProjects
import Foundation
import GRDB

extension SimpleServiceStore {
  func insertTask(_ task: ServiceTaskRecord, in db: Database) throws {
    let changedFiles = try encoder.encode(task.state.changedFiles)
    guard changedFiles.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("task.changedFiles")
    }
    try db.execute(
      sql: """
        INSERT INTO bridge_service_tasks (
          task_id, project_id, source, source_client_id, client_request_id, prompt, requested_thread_id,
          codex_thread_id, codex_turn_id, status, supervisor_status, execution_model,
          execution_effort, supervisor_model, supervisor_effort, permission_mode,
          network_allowed, access_mode, fast_mode, current_step, changed_files_json,
          result_summary, supervisor_summary, failure_code, created_at, updated_at,
          provider_id, installation_id, selection_mode, provider_session_id, provider_run_id
        ) VALUES (
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?
        )
        """,
      arguments: Self.taskArguments(task, changedFiles: changedFiles)
    )
  }

  func updateTaskRow(_ task: ServiceTaskRecord, in db: Database) throws {
    let changedFiles = try encoder.encode(task.state.changedFiles)
    guard changedFiles.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("task.changedFiles")
    }
    try db.execute(
      sql: """
        UPDATE bridge_service_tasks
        SET codex_thread_id = ?, codex_turn_id = ?, status = ?, supervisor_status = ?,
            current_step = ?, changed_files_json = ?, result_summary = ?,
            supervisor_summary = ?, failure_code = ?, updated_at = ?,
            provider_session_id = ?, provider_run_id = ?
        WHERE task_id = ?
        """,
      arguments: [
        task.state.codexThreadID,
        task.state.codexTurnID,
        task.state.status.rawValue,
        task.state.supervisorStatus.rawValue,
        task.state.currentStep,
        changedFiles,
        task.state.resultSummary,
        task.state.supervisorSummary,
        task.state.failureCode,
        task.updatedAt.timeIntervalSince1970,
        task.state.providerSessionID,
        task.state.providerRunID,
        task.id.rawValue,
      ]
    )
    guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
  }

  func existingIdempotentTask(for task: ServiceTaskRecord) throws -> ServiceTaskRecord? {
    try database.read { db in
      try Self.idempotentTask(for: task, in: db)
    }
  }

  static func reusedResult(
    existing: ServiceTaskRecord,
    requested: ServiceTaskRecord
  ) throws -> ServiceTaskCreationResult {
    guard existing.hasSameSubmission(as: requested) else {
      if let clientRequestID = requested.clientRequestID {
        throw ServiceStoreError.idempotencyConflict(
          source: requested.source,
          clientRequestID: clientRequestID
        )
      }
      throw ServiceStoreError.duplicateTask(requested.id)
    }
    return ServiceTaskCreationResult(task: existing, reusedExistingTask: true)
  }

  static func validateTransition(
    from source: ServiceTaskStatus,
    to destination: ServiceTaskStatus
  ) throws {
    guard source != destination else { return }
    let allowed: Set<ServiceTaskStatus>
    switch source {
    case .awaitingLocalApproval:
      allowed = [.starting, .failed, .interrupted]
    case .starting:
      allowed = [.running, .failed, .interrupted, .unknown]
    case .running:
      allowed = [.waitingForCodexApproval, .completed, .failed, .interrupted, .unknown]
    case .waitingForCodexApproval:
      allowed = [.running, .failed, .interrupted, .unknown]
    case .unknown:
      allowed = [.failed, .interrupted]
    case .completed, .failed, .interrupted:
      allowed = []
    }
    guard allowed.contains(destination) else {
      throw ServiceStoreError.invalidTaskTransition(from: source, to: destination)
    }
  }

  static func insert(_ project: ServiceProjectRecord, in db: Database) throws {
    let workspaceCommands = try JSONEncoder().encode(project.workspaceCommands)
    let commandBlacklist = try JSONEncoder().encode(project.commandBlacklist)
    guard workspaceCommands.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    try db.execute(
      sql: """
        INSERT INTO bridge_service_projects (
          project_id, name, canonical_path, root_device, root_inode, root_volume_uuid,
          read_permission, write_permission, network_permission, created_at, updated_at,
          direct_command_mode, workspace_commands_json,
          direct_blacklist_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        project.id.rawValue,
        project.name,
        project.root.canonicalPath,
        String(project.root.device),
        String(project.root.inode),
        project.root.volumeUUID,
        project.accessPolicy.read.rawValue,
        project.accessPolicy.write.rawValue,
        project.accessPolicy.network.rawValue,
        project.createdAt.timeIntervalSince1970,
        project.updatedAt.timeIntervalSince1970,
        project.directCommandMode.rawValue,
        workspaceCommands,
        commandBlacklist,
      ]
    )
  }

  static func insert(
    _ event: ServiceTaskEventDraft,
    taskID: TaskID,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_events (task_id, kind, summary, created_at)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        taskID.rawValue,
        event.kind.rawValue,
        event.summary,
        event.createdAt.timeIntervalSince1970,
      ]
    )
  }

  static func upsertTaskMessage(
    _ message: ServiceTaskMessageDraft,
    taskID: TaskID,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_messages (
          task_id, message_key, role, kind, content, tool_name, tool_status,
          tool_arguments, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(task_id, message_key) DO UPDATE SET
          content = excluded.content,
          tool_name = excluded.tool_name,
          tool_status = excluded.tool_status,
          tool_arguments = excluded.tool_arguments,
          created_at = excluded.created_at
        """,
      arguments: [
        taskID.rawValue,
        message.key,
        message.role.rawValue,
        message.kind.rawValue,
        message.content,
        message.toolName,
        message.toolStatus,
        message.toolArguments,
        message.createdAt.timeIntervalSince1970,
      ]
    )
  }

  static func taskMessageRow(
    taskID: TaskID,
    key: String,
    in db: Database
  ) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM bridge_service_task_messages
        WHERE task_id = ? AND message_key = ?
        """,
      arguments: [taskID.rawValue, key]
    )
  }

  static func taskArguments(
    _ task: ServiceTaskRecord,
    changedFiles: Data
  ) -> StatementArguments {
    [
      task.id.rawValue,
      task.projectID.rawValue,
      task.source.rawValue,
      task.sourceClientID,
      task.clientRequestID,
      task.prompt,
      task.requestedThreadID,
      task.state.codexThreadID,
      task.state.codexTurnID,
      task.state.status.rawValue,
      task.state.supervisorStatus.rawValue,
      task.executionModel,
      task.executionEffort,
      task.supervisorModel,
      task.supervisorEffort,
      task.permissionMode.rawValue,
      task.networkAllowed ? 1 : 0,
      task.accessMode.rawValue,
      task.fastMode ? 1 : 0,
      task.state.currentStep,
      changedFiles,
      task.state.resultSummary,
      task.state.supervisorSummary,
      task.state.failureCode,
      task.createdAt.timeIntervalSince1970,
      task.updatedAt.timeIntervalSince1970,
      task.providerID,
      task.installationID,
      task.selectionMode.rawValue,
      task.state.providerSessionID,
      task.state.providerRunID,
    ]
  }

  static func projectRow(id: ProjectID, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM bridge_service_projects WHERE project_id = ?",
      arguments: [id.rawValue]
    )
  }

  static func projectRow(root: ServiceRootIdentity, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM bridge_service_projects
        WHERE canonical_path = ?
           OR (
             root_inode = ?
             AND (
               (root_volume_uuid IS NOT NULL AND root_volume_uuid = ?)
               OR (root_volume_uuid IS NULL AND root_device = ?)
             )
           )
        LIMIT 1
        """,
      arguments: [
        root.canonicalPath,
        String(root.inode),
        root.volumeUUID,
        String(root.device),
      ]
    )
  }

  static func taskRow(id: TaskID, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM bridge_service_tasks WHERE task_id = ?",
      arguments: [id.rawValue]
    )
  }

  static func idempotentTask(
    for task: ServiceTaskRecord,
    in db: Database
  ) throws -> ServiceTaskRecord? {
    guard let clientRequestID = task.clientRequestID else { return nil }
    return try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM bridge_service_tasks
        WHERE source = ? AND source_client_id = ? AND client_request_id = ?
        """,
      arguments: [task.source.rawValue, task.sourceClientID, clientRequestID]
    ).map(Self.decodeTask)
  }

  static func activeWriteTaskRow(
    projectID: ProjectID,
    in db: Database
  ) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM bridge_service_tasks
        WHERE project_id = ?
          AND permission_mode = 'workspace-write'
          AND status IN (
            'awaiting_local_approval', 'starting', 'running',
            'waiting_for_codex_approval', 'unknown'
          )
        ORDER BY created_at, task_id
        LIMIT 1
        """,
      arguments: [projectID.rawValue]
    )
  }

  static func decodeProject(_ row: Row) throws -> ServiceProjectRecord {
    guard let device = UInt64(row["root_device"] as String),
      let inode = UInt64(row["root_inode"] as String),
      let directCommandMode = ServiceDirectCommandMode(rawValue: row["direct_command_mode"])
    else {
      throw ServiceStoreError.corruptRecord
    }
    let workspaceCommandsData: Data = row["workspace_commands_json"]
    let workspaceCommands: [ServiceWorkspaceCommand]
    do {
      workspaceCommands = try JSONDecoder().decode(
        [ServiceWorkspaceCommand].self, from: workspaceCommandsData)
    } catch {
      throw ServiceStoreError.corruptRecord
    }
    let commandBlacklist: [ServiceCommandBlacklistRule]
    do {
      commandBlacklist = try JSONDecoder().decode(
        [ServiceCommandBlacklistRule].self, from: row["direct_blacklist_json"])
    } catch {
      throw ServiceStoreError.corruptRecord
    }
    return try ServiceProjectRecord(
      id: ProjectID(rawValue: row["project_id"]),
      name: row["name"],
      root: ServiceRootIdentity(
        canonicalPath: row["canonical_path"],
        device: device,
        inode: inode,
        volumeUUID: row["root_volume_uuid"]
      ),
      accessPolicy: ProjectAccessPolicy(
        read: ProjectPermission(rawValue: row["read_permission"]),
        write: ProjectPermission(rawValue: row["write_permission"]),
        network: ProjectPermission(rawValue: row["network_permission"])
      ),
      directCommandMode: directCommandMode,
      workspaceCommands: workspaceCommands,
      commandBlacklist: commandBlacklist,
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }

  static func decodeTask(_ row: Row) throws -> ServiceTaskRecord {
    guard let source = ServiceTaskSource(rawValue: row["source"]),
      let status = ServiceTaskStatus(rawValue: row["status"]),
      let supervisorStatus = ServiceSupervisorStatus(rawValue: row["supervisor_status"]),
      let permissionMode = ServicePermissionMode(rawValue: row["permission_mode"]),
      let accessMode = ServiceAccessMode(rawValue: row["access_mode"])
    else {
      throw ServiceStoreError.corruptRecord
    }
    guard let providerID: String = row["provider_id"],
      let selectionMode = ServiceAgentSelectionMode(rawValue: row["selection_mode"])
    else {
      throw ServiceStoreError.corruptRecord
    }
    let installationID: String? = row["installation_id"]
    let fastModeValue: Int = row["fast_mode"]
    guard fastModeValue == 0 || fastModeValue == 1 else {
      throw ServiceStoreError.corruptRecord
    }
    let changedData: Data = row["changed_files_json"]
    let changedFiles: [String]
    do {
      changedFiles = try JSONDecoder().decode([String].self, from: changedData)
    } catch {
      throw ServiceStoreError.corruptRecord
    }
    let networkAllowedValue: Int = row["network_allowed"]
    guard networkAllowedValue == 0 || networkAllowedValue == 1 else {
      throw ServiceStoreError.corruptRecord
    }
    let state = try ServiceTaskState(
      codexThreadID: row["codex_thread_id"],
      codexTurnID: row["codex_turn_id"],
      providerSessionID: row["provider_session_id"],
      providerRunID: row["provider_run_id"],
      status: status,
      supervisorStatus: supervisorStatus,
      currentStep: row["current_step"],
      changedFiles: changedFiles,
      resultSummary: row["result_summary"],
      supervisorSummary: row["supervisor_summary"],
      failureCode: row["failure_code"]
    )
    return try ServiceTaskRecord(
      id: TaskID(rawValue: row["task_id"]),
      projectID: ProjectID(rawValue: row["project_id"]),
      source: source,
      sourceClientID: row["source_client_id"],
      clientRequestID: row["client_request_id"],
      prompt: row["prompt"],
      requestedThreadID: row["requested_thread_id"],
      providerID: providerID,
      installationID: installationID,
      selectionMode: selectionMode,
      executionModel: row["execution_model"],
      executionEffort: row["execution_effort"],
      supervisorModel: row["supervisor_model"],
      supervisorEffort: row["supervisor_effort"],
      permissionMode: permissionMode,
      networkAllowed: networkAllowedValue == 1,
      accessMode: accessMode,
      fastMode: fastModeValue == 1,
      state: state,
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }

  static func decodeEvent(_ row: Row) throws -> ServiceTaskEventRecord {
    guard let kind = ServiceTaskEventKind(rawValue: row["kind"]) else {
      throw ServiceStoreError.corruptRecord
    }
    return try ServiceTaskEventRecord(
      id: row["event_id"],
      taskID: TaskID(rawValue: row["task_id"]),
      kind: kind,
      summary: row["summary"],
      createdAt: Date(timeIntervalSince1970: row["created_at"])
    )
  }

  static func decodeTaskMessage(_ row: Row) throws -> ServiceTaskMessageRecord {
    guard let role = ServiceTaskMessageRole(rawValue: row["role"]) else {
      throw ServiceStoreError.corruptRecord
    }
    let kind: ServiceTaskMessageKind
    if let rawKind: String = row["kind"] {
      kind = ServiceTaskMessageKind(rawValue: rawKind) ?? .agent
    } else {
      kind = .agent
    }
    return try ServiceTaskMessageRecord(
      id: row["message_id"],
      taskID: TaskID(rawValue: row["task_id"]),
      key: row["message_key"],
      role: role,
      content: row["content"],
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      kind: kind,
      toolName: row["tool_name"],
      toolStatus: row["tool_status"],
      toolArguments: row["tool_arguments"]
    )
  }

  static func decodeSetting(_ row: Row) throws -> ServiceSettingRecord {
    try ServiceSettingRecord(
      key: row["setting_key"],
      value: row["setting_value"],
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }
}
