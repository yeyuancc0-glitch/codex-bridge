import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try await serviceSubmitTask(
      submission,
      invocationContext: MCPInvocationContext(clientID: .chatGPT),
      deadline: deadline
    )
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
      source: task.source.rawValue,
      sourceClientID: task.sourceClientID.isEmpty ? nil : task.sourceClientID,
      status: task.state.status.rawValue,
      executionModel: task.executionModel,
      executionEffort: task.executionEffort,
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
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try Self.checkDeadline(deadline)
    let prepared = try await prepareTaskSubmission(
      submission,
      sourceClientID: invocationContext.clientID.rawValue,
      deadline: deadline
    )
    let result = try await submitTaskWithAdmission(
      prepared.request,
      projectID: prepared.projectID
    )
    if !result.reusedExistingTask {
      try await beginAndStartTask(result.task.id)
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

  private struct PreparedTaskSubmission {
    let projectID: ProjectID
    let request: ServiceTaskRequest
  }

  private func prepareTaskSubmission(
    _ submission: MCPServiceTaskSubmission,
    sourceClientID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let projectID = try await submissionProjectID(explicit: submission.projectID)
    let project = try await readableProject(projectID)
    let models = try await catalog.listModels(deadline: deadline).models
    let selections = try await modelSelections(submission: submission, models: models)
    let permission = try Self.permissionMode(submission.permissionMode, project: project)
    let accessMode = try await settings.accessMode()
    let fastMode =
      try await settings.isFastModeEnabled()
      && models.first(where: { $0.modelID == selections.execution.model })?
        .supportsFastMode == true
    guard !submission.networkAccess || project.accessPolicy.network != .denied else {
      throw BridgeMCPQueryError.contractRejected
    }
    let taskPrompt = try await taskPrompt(for: submission, project: project, deadline: deadline)
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: sourceClientID,
        clientRequestID: submission.clientRequestID,
        prompt: taskPrompt,
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
  }

  private func submissionProjectID(explicit: String?) async throws -> String {
    if let explicit { return explicit }
    if let selected = try await settings.string(for: .workbenchProjectID), !selected.isEmpty,
      selected.utf8.count <= 128, !selected.contains("\0"),
      try await projects.project(id: ProjectID(rawValue: selected)) != nil
    {
      return selected
    }
    guard let fallback = Self.sortedProjects(try await projects.projects()).first else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return fallback.id.rawValue
  }

  private func taskPrompt(
    for submission: MCPServiceTaskSubmission,
    project: ServiceProjectRecord,
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    var prompt = Self.prompt(
      submission.prompt,
      acceptanceCriteria: submission.acceptanceCriteria
    )
    if let skillName = submission.skillName {
      let skill = try await serviceReadSkill(
        skillName: skillName,
        projectID: project.id.rawValue,
        subpath: "SKILL.md",
        deadline: deadline
      )
      let instructions = String(skill.content.prefix(8 * 1_024))
      prompt =
        "Skill instructions for \(skill.name):\n\n\(instructions)\n\nUser task:\n\(prompt)"
    }
    guard prompt.utf8.count <= 32 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return prompt
  }

  private func submitTaskWithAdmission(
    _ request: ServiceTaskRequest,
    projectID: ProjectID
  ) async throws -> ServiceTaskCreationResult {
    do {
      try await workspaceGate.beginCodexAdmission(projectID: projectID)
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      let result = try await tasks.submit(request)
      await workspaceGate.endCodexAdmission(projectID: projectID)
      return result
    } catch {
      await workspaceGate.endCodexAdmission(projectID: projectID)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
  }

  private func beginAndStartTask(_ taskID: TaskID) async throws {
    let started: ServiceTaskRecord
    do {
      started = try await tasks.begin(taskID: taskID)
    } catch {
      _ = try? await tasks.interrupt(
        taskID: taskID,
        summary: "Codex execution could not enter the starting state."
      )
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
    do {
      try await coordinator.start(taskID: started.id)
    } catch {
      throw Self.publicExecutionError(error)
    }
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
}
