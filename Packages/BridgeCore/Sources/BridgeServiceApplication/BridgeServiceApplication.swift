import BridgeCodexService
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation

public struct ServiceModelCatalog: Equatable, Sendable {
  public let models: MCPModelList
  public let preferences: ServiceModelPreferences

  public init(models: MCPModelList, preferences: ServiceModelPreferences) {
    self.models = models
    self.preferences = preferences
  }
}

public actor BridgeServiceApplication: BridgeMCPServiceAPI {
  let appVersion: String
  let projects: ServiceProjectService
  let tasks: ServiceTaskManager
  let settings: ServiceSettings
  let coordinator: ServiceExecutionCoordinator
  let catalog: ServiceCodexCatalog
  let files: RestrictedProjectFileService
  let mutations: RestrictedProjectMutationService
  let runtimeStatus: ServiceRuntimeStatus
  let workspaceGate: ServiceWorkspaceMutationGate
  private let iso8601 = ISO8601DateFormatter()

  public init(
    appVersion: String,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    settings: ServiceSettings,
    coordinator: ServiceExecutionCoordinator,
    catalog: ServiceCodexCatalog,
    runtimeStatus: ServiceRuntimeStatus,
    files: RestrictedProjectFileService? = nil,
    mutations: RestrictedProjectMutationService? = nil,
    workspaceGate: ServiceWorkspaceMutationGate? = nil
  ) {
    precondition(!appVersion.isEmpty)
    self.appVersion = appVersion
    self.projects = projects
    self.tasks = tasks
    self.settings = settings
    self.coordinator = coordinator
    self.catalog = catalog
    self.runtimeStatus = runtimeStatus
    let repository = ServiceProjectRepositoryAdapter(projects: projects)
    self.files =
      files
      ?? RestrictedProjectFileService(repository: repository)
    self.mutations =
      mutations
      ?? RestrictedProjectMutationService(repository: repository)
    self.workspaceGate = workspaceGate ?? ServiceWorkspaceMutationGate()
  }

  public func serviceStatus(
    deadline: ContinuousClock.Instant
  ) async throws -> BridgeStatusSnapshot {
    try Self.checkDeadline(deadline)
    let taskList = try await tasks.tasks(limit: 500)
    let runtime = await runtimeStatus.current()
    let codexApprovals = await coordinator.pendingApprovals().count
    return BridgeStatusSnapshot(
      appVersion: appVersion,
      mcpState: runtime.mcpState,
      tunnelState: runtime.tunnelState,
      codexVersion: runtime.codexVersion,
      loginMode: runtime.loginMode,
      executionState: Self.executionState(taskList),
      supervisorState: Self.supervisorState(taskList),
      degradations: runtime.degradations,
      pendingApprovalCount: codexApprovals
    )
  }

  public func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    try Self.checkDeadline(deadline)
    guard (1...100).contains(limit) else { throw BridgeMCPQueryError.contractRejected }
    let all = try await projects.projects()
    let visible = all.filter { $0.accessPolicy.read == .allowed }.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id.rawValue < $1.id.rawValue : order == .orderedAscending
    }
    let offset = try Self.decodeOffset(cursor, maximum: visible.count)
    let end = min(offset + limit, visible.count)
    let page = visible[offset..<end].map(Self.projectSummary)
    return MCPProjectPage(
      projects: Array(page),
      nextCursor: end < visible.count ? "v1.\(end)" : nil
    )
  }

  public func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    return MCPProjectDetail(
      projectID: project.id.rawValue,
      name: Self.safe(project.name, maximum: 1_024),
      capabilities: Self.capabilities(project.accessPolicy),
      verificationCommands: [],
      directWorkspace: MCPDirectWorkspace(
        fileWritePermission: project.accessPolicy.write.rawValue,
        commandMode: project.directCommandMode.rawValue,
        commands: project.workspaceCommands.map(Self.projectCommand)
      )
    )
  }

  public func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    return MCPProjectCommands(
      commandMode: project.directCommandMode.rawValue,
      commands: project.workspaceCommands.map(Self.projectCommand)
    )
  }

  public func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.search(
        ProjectFileSearchRequest(
          projectID: ProjectID(rawValue: projectID),
          query: query,
          relativeDirectory: relativeDirectory,
          caseSensitive: caseSensitive,
          limit: limit,
          cursor: cursor
        )
      )
      return MCPProjectFileSearchPage(
        matches: result.matches.map {
          MCPProjectFileSearchMatch(
            relativePath: $0.relativePath,
            lineNumber: $0.lineNumber,
            preview: $0.preview,
            redacted: $0.redacted
          )
        },
        nextCursor: result.nextCursor,
        skippedFileCount: result.skippedFileCount
      )
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: relativePath,
          lineRange: try FileLineRange(startLine: startLine, lineCount: lineCount)
        )
      )
      return MCPProjectFileReadPage(
        relativePath: result.relativePath,
        startLine: result.startLine,
        endLine: result.endLine,
        content: result.content,
        redactedLineCount: result.redactedLineCount,
        truncated: result.truncated,
        nextStartLine: result.nextStartLine,
        sha256: result.sha256,
        byteCount: result.byteCount
      )
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    let project = try await readableProject(projectID)
    return try await catalog.listThreads(
      root: project.root.canonicalPath,
      cursor: cursor,
      limit: limit,
      search: search,
      deadline: deadline
    )
  }

  public func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    let project = try await readableProject(projectID)
    return try await catalog.readThread(
      root: project.root.canonicalPath,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  public func serviceModels(
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    try await catalog.listModels(deadline: deadline)
  }

  public func serviceModelPreferences(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelPreferences {
    try await serviceModelCatalog(deadline: deadline).preferences
  }

  public func serviceModelCatalog(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelCatalog {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline)
    let preferences = try await resolvedDefaultModelPreferences(models: models.models)
    return ServiceModelCatalog(models: models, preferences: preferences)
  }

  public func setServiceModelPreferences(
    _ preferences: ServiceModelPreferences,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline).models
    _ = try Self.select(
      modelID: preferences.executionModel,
      effort: preferences.executionEffort,
      models: models
    )
    _ = try Self.select(
      modelID: preferences.supervisorModel,
      effort: preferences.supervisorEffort,
      models: models
    )
    try Self.checkDeadline(deadline)
    try await settings.setModelPreferences(preferences)
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    try await settings.setSupervisorEnabled(enabled)
  }

  public func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    let events = try await tasks.events(taskID: id, limit: recentEventLimit)
    return MCPServiceTaskSnapshot(
      taskID: task.id.rawValue,
      projectID: task.projectID.rawValue,
      status: task.state.status.rawValue,
      threadID: task.state.codexThreadID,
      turnID: task.state.codexTurnID,
      currentStep: task.state.currentStep,
      changedFiles: task.state.changedFiles,
      recentEvents: events.map {
        MCPServiceTaskEvent(
          sequence: $0.id,
          kind: $0.kind.rawValue,
          summary: Self.safe($0.summary, maximum: 8 * 1_024),
          occurredAt: iso8601.string(from: $0.createdAt)
        )
      },
      supervisorStatus: task.state.supervisorStatus.rawValue,
      supervisorSummary: task.state.supervisorSummary,
      localApprovalRequired: task.state.status == .awaitingLocalApproval
        || task.state.status == .waitingForCodexApproval,
      resultSummary: task.state.resultSummary,
      failureCode: task.state.failureCode,
      updatedAt: iso8601.string(from: task.updatedAt)
    )
  }

  public func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(submission.projectID)
    let models = try await catalog.listModels(deadline: deadline).models
    let selections = try await modelSelections(submission: submission, models: models)
    let permission = try Self.permissionMode(
      submission.permissionMode,
      project: project
    )
    let accessMode = try await settings.accessMode()
    let fastMode =
      try await settings.isFastModeEnabled()
      && models.first(where: { $0.modelID == selections.execution.model })?
        .supportsFastMode == true
    guard !submission.networkAccess || project.accessPolicy.network != .denied else {
      throw BridgeMCPQueryError.contractRejected
    }
    let result: ServiceTaskCreationResult
    do {
      try await workspaceGate.beginCodexAdmission(projectID: project.id)
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      result = try await tasks.submit(
        ServiceTaskRequest(
          projectID: project.id,
          source: .chatGPT,
          clientRequestID: submission.clientRequestID,
          prompt: Self.prompt(
            submission.prompt,
            acceptanceCriteria: submission.acceptanceCriteria
          ),
          requestedThreadID: submission.threadID,
          executionModel: selections.execution.model,
          executionEffort: selections.execution.effort,
          supervisorModel: selections.supervisor?.model,
          supervisorEffort: selections.supervisor?.effort,
          permissionMode: permission,
          networkAllowed: submission.networkAccess,
          accessMode: accessMode,
          fastMode: fastMode
        )
      )
      await workspaceGate.endCodexAdmission(projectID: project.id)
    } catch {
      await workspaceGate.endCodexAdmission(projectID: project.id)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
    if !result.reusedExistingTask {
      let started = try await tasks.begin(taskID: result.task.id)
      do {
        try await coordinator.start(taskID: started.id)
      } catch {
        throw Self.publicExecutionError(error)
      }
    }
    let task = try await tasks.task(id: result.task.id)
    let latest = task ?? result.task
    return MCPServiceTaskSubmissionReceipt(
      taskID: latest.id.rawValue,
      status: latest.state.status.rawValue,
      reusedExistingTask: result.reusedExistingTask,
      localApprovalRequired: false
    )
  }

  public func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    guard task.state.status == .running, task.state.codexTurnID == expectedTurnID else {
      throw BridgeMCPQueryError.turnMismatch
    }
    do {
      try await coordinator.steer(
        taskID: id,
        expectedTurnID: expectedTurnID,
        text: input
      )
    } catch {
      throw Self.publicExecutionError(error)
    }
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: task.state.status.rawValue,
      accepted: true
    )
  }

  public func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    guard task.state.status == .running, task.state.codexTurnID == expectedTurnID else {
      throw BridgeMCPQueryError.turnMismatch
    }
    do {
      try await coordinator.interrupt(taskID: id, expectedTurnID: expectedTurnID)
    } catch {
      throw Self.publicExecutionError(error)
    }
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: task.state.status.rawValue,
      accepted: true
    )
  }

  public func pendingCodexApprovals(taskID: TaskID? = nil) async
    -> [ExecutionApprovalRequest]
  {
    await coordinator.pendingApprovals(taskID: taskID)
  }

  public func resolveCodexApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    try await coordinator.resolveApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision
    )
  }

  public func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    let changes = try await mutations.changes(projectID: project.id)
    return MCPProjectChanges(
      changedFiles: changes.changedFiles,
      diff: Self.safe(changes.diff, maximum: 200 * 1_024),
      additions: changes.additions,
      deletions: changes.deletions,
      truncated: changes.truncated,
      notGitRepository: changes.notGitRepository
    )
  }

  public func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let result = try await mutations.write(
        ProjectWriteRequest(
          projectID: project.id,
          relativePath: request.relativePath,
          mode: request.mode == "create" ? .create : .replace,
          content: request.content,
          expectedSHA256: request.expectedSHA256,
          createParents: request.createParents
        )
      )
      await lease.release()
      return MCPDirectWriteReceipt(
        relativePath: result.relativePath,
        operation: result.operation,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount,
        boundedDiff: MCPBoundedDiff(
          removedLines: result.boundedDiff.removedLines,
          addedLines: result.boundedDiff.addedLines,
          truncated: result.boundedDiff.truncated,
          byteCount: result.boundedDiff.byteCount
        )
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let result = try await mutations.edit(
        ProjectEditRequest(
          projectID: project.id,
          relativePath: request.relativePath,
          expectedSHA256: request.expectedSHA256,
          oldText: request.oldText,
          newText: request.newText,
          expectedReplacements: request.expectedReplacements
        )
      )
      await lease.release()
      return MCPDirectWriteReceipt(
        relativePath: result.relativePath,
        operation: result.operation,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount,
        boundedDiff: MCPBoundedDiff(
          removedLines: result.boundedDiff.removedLines,
          addedLines: result.boundedDiff.addedLines,
          truncated: result.boundedDiff.truncated,
          byteCount: result.boundedDiff.byteCount
        )
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let operations: [ProjectPatchFileOperation]
      do {
        operations = try ProjectPatchParser.parse(request.patch)
      } catch {
        throw BridgeMCPQueryError.invalidPatch
      }
      let results = try await mutations.applyPatch(
        ProjectApplyPatchRequest(
          projectID: project.id,
          operations: operations
        )
      )
      await lease.release()
      let receipts = results.map { result in
        MCPDirectWriteReceipt(
          relativePath: result.relativePath,
          operation: result.operation,
          oldSHA256: result.oldSHA256,
          newSHA256: result.newSHA256,
          byteCount: result.byteCount,
          boundedDiff: MCPBoundedDiff(
            removedLines: result.boundedDiff.removedLines,
            addedLines: result.boundedDiff.addedLines,
            truncated: result.boundedDiff.truncated,
            byteCount: result.boundedDiff.byteCount
          )
        )
      }
      return MCPDirectPatchReceipt(operations: receipts)
    } catch let error as ProjectMutationError {
      await lease.release()
      if case .partialCommit(let changedFiles, let rollbackStatus) = error {
        return MCPDirectPatchReceipt(
          operations: [],
          partialCommit: MCPPartialCommit(
            changedFiles: changedFiles,
            rollbackStatus: rollbackStatus
          )
        )
      }
      throw Self.publicMutationError(error)
    } catch {
      await lease.release()
      throw error
    }
  }

  public func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let action = ProjectPathAction(rawValue: request.action) ?? .deleteFile
      let result = try await mutations.managePath(
        ProjectManagePathRequest(
          projectID: project.id,
          action: action,
          relativePath: request.relativePath,
          expectedSHA256: request.expectedSHA256,
          destinationRelativePath: request.destinationRelativePath,
          sourceExpectedSHA256: request.sourceExpectedSHA256,
          destinationExpectedAbsent: request.destinationExpectedAbsent
        )
      )
      await lease.release()
      return MCPDirectManagePathReceipt(
        relativePath: result.relativePath,
        operation: result.operation,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  private func acquireDirectLease(
    project: ServiceProjectRecord,
    owner: ServiceWorkspaceOwner
  ) async throws -> DirectWorkspaceLease {
    do {
      return try await workspaceGate.acquireDirectLease(
        projectID: project.id,
        owner: owner,
        activeCodexWriteTask: { try await self.tasks.activeWriteTask(projectID: project.id) }
      )
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
  }
}
