import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
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
    var taskPrompt = Self.prompt(
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
      taskPrompt =
        "Skill instructions for \(skill.name):\n\n\(instructions)\n\nUser task:\n\(taskPrompt)"
    }
    guard taskPrompt.utf8.count <= 32 * 1_024 else {
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
      await workspaceGate.endCodexAdmission(projectID: project.id)
    } catch {
      await workspaceGate.endCodexAdmission(projectID: project.id)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
    if !result.reusedExistingTask {
      let started: ServiceTaskRecord
      do {
        started = try await tasks.begin(taskID: result.task.id)
      } catch {
        _ = try? await tasks.interrupt(
          taskID: result.task.id,
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
}
