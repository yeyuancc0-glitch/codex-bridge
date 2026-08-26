import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public struct PendingTaskStartApproval: Equatable, Sendable {
    public let approvalID: String
    public let taskID: String
    public let projectID: String
    public let clientID: String
    public let prompt: String
    public let providerID: String
    public let permissionMode: String
    public let networkAllowed: Bool

    public var providerDisplayName: String {
      providerID == AgentProviderID.openCode.rawValue ? "OpenCode" : "Codex"
    }

    public init(task: ServiceTaskRecord) {
      approvalID = Self.approvalID(for: task.id)
      taskID = task.id.rawValue
      projectID = task.projectID.rawValue
      clientID = task.source == .chatGPT ? MCPClientID.chatGPT.rawValue : task.sourceClientID
      prompt = task.prompt
      providerID = task.providerID
      permissionMode = task.permissionMode.rawValue
      networkAllowed = task.networkAllowed
    }

    public static func approvalID(for taskID: TaskID) -> String {
      "bridge-task-start:\(taskID.rawValue)"
    }
  }

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
    let isCodexProvider = task.providerID == serviceCodexProviderID
    return MCPServiceTaskSnapshot(
      taskID: task.id.rawValue,
      projectID: task.projectID.rawValue,
      source: task.source.rawValue,
      sourceClientID: task.sourceClientID.isEmpty ? nil : task.sourceClientID,
      status: task.state.status.rawValue,
      providerID: task.providerID,
      installationID: task.installationID,
      executionModel: task.executionModel,
      executionEffort: task.executionEffort,
      threadID: isCodexProvider ? task.state.codexThreadID : nil,
      turnID: isCodexProvider ? task.state.codexTurnID : nil,
      providerSessionID: isCodexProvider ? nil : task.state.providerSessionID,
      providerRunID: isCodexProvider ? nil : task.state.providerRunID,
      permissionMode: task.permissionMode.rawValue,
      networkAccess: task.networkAllowed,
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
    let task = try await tasks.task(id: result.task.id)
    let latest = task ?? result.task
    return MCPServiceTaskSubmissionReceipt(
      taskID: latest.id.rawValue,
      status: latest.state.status.rawValue,
      reusedExistingTask: result.reusedExistingTask,
      localApprovalRequired: latest.state.status == .awaitingLocalApproval
    )
  }

  public func pendingTaskStartApprovals(taskID: TaskID? = nil) async throws
    -> [PendingTaskStartApproval]
  {
    let taskList: [ServiceTaskRecord]
    if let taskID {
      taskList = try await tasks.task(id: taskID).map { [$0] } ?? []
    } else {
      taskList = try await tasks.tasks(limit: 500)
    }
    return taskList.compactMap { task in
      guard task.state.status == .awaitingLocalApproval,
        task.requiresLocalStartApproval
      else {
        return nil
      }
      return PendingTaskStartApproval(task: task)
    }
  }

  public func resolveTaskStartApproval(
    taskID: TaskID,
    approvalID: String,
    approved: Bool,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard approvalID == PendingTaskStartApproval.approvalID(for: taskID),
      let task = try await tasks.task(id: taskID),
      task.state.status == .awaitingLocalApproval,
      task.requiresLocalStartApproval
    else {
      throw BridgeMCPQueryError.approvalExpired
    }
    if approved {
      try await approveAndStartTask(taskID)
    } else {
      do {
        _ = try await tasks.denyStart(taskID: taskID)
      } catch ServiceStoreError.invalidTaskTransition {
        throw BridgeMCPQueryError.approvalExpired
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      } catch {
        throw error
      }
    }
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
    if let providerRaw = submission.providerID {
      return try await prepareAgentSubmission(
        submission,
        providerRaw: providerRaw,
        project: project,
        sourceClientID: sourceClientID
      )
    }
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

  /// Explicit non-Codex submissions resolve against the user-registered agent
  /// installations. The provider owns defaults unless the caller explicitly
  /// opts into a model override; permission follows the project policy used by
  /// the Codex path, while network access remains governed by native ACP
  /// permissions and is unavailable as a Bridge task option.
  private func prepareAgentSubmission(
    _ submission: MCPServiceTaskSubmission,
    providerRaw: String,
    project: ServiceProjectRecord,
    sourceClientID: String
  ) async throws -> PreparedTaskSubmission {
    guard providerRaw == AgentProviderID.openCode.rawValue else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard
      submission.threadID == nil,
      submission.supervisorModel == nil,
      submission.supervisorEffort == nil,
      submission.skillName == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    // Resolution order mirrors Codex: explicit override > Bridge default
    // setting > provider default. Unmarked model fields stay ignored for
    // compatibility with old clients.
    let usesOverride = submission.modelOverride == true
    let requestedModel = usesOverride ? submission.executionModel : nil
    if let model = requestedModel {
      guard !model.isEmpty, model.utf8.count <= 256,
        model.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw BridgeMCPQueryError.contractRejected
      }
    }
    let configuredModel = try await settings.string(for: .openCodeDefaultModel)
    let resolvedModel = try Self.validatedAgentModel(
      requestedModel ?? configuredModel
    )
    let requestedEffort = usesOverride ? submission.executionEffort : nil
    guard requestedEffort == nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    let permission = try Self.permissionMode(submission.permissionMode, project: project)
    guard !submission.networkAccess else {
      // OpenCode's ACP mode does not expose a per-task network sandbox. Do
      // not persist a requested network grant as though Bridge enforced it.
      throw BridgeMCPQueryError.unavailable
    }
    let registry = try requiredAgentRegistry()
    let selectable =
      try await registry
      .installations(providerID: .openCode)
      .filter { $0.isSelectable }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    let record = try Self.selectAgentInstallation(
      requested: submission.installationID, from: selectable)
    let prompt = Self.prompt(submission.prompt, acceptanceCriteria: submission.acceptanceCriteria)
    guard prompt.utf8.count <= 32 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    let accessMode = try await settings.accessMode()
    let executionModel = resolvedModel ?? serviceDefaultProviderExecutionModel
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: sourceClientID,
        clientRequestID: submission.clientRequestID,
        prompt: prompt,
        providerID: AgentProviderID.openCode.rawValue,
        installationID: record.id.rawValue,
        selectionMode: .explicit,
        executionModel: executionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: permission,
        networkAllowed: false,
        accessMode: accessMode
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

  static func validatedAgentModel(_ model: String?) throws -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return trimmed
  }

  static func selectAgentInstallation(
    requested: String?,
    from selectable: [ServiceAgentInstallationRecord]
  ) throws -> ServiceAgentInstallationRecord {
    if let requested {
      guard let record = selectable.first(where: { $0.id.rawValue == requested }) else {
        throw BridgeMCPQueryError.unavailable
      }
      return record
    }
    guard let record = selectable.first else {
      throw BridgeMCPQueryError.unavailable
    }
    return record
  }

  private func submitTaskWithAdmission(
    _ request: ServiceTaskRequest,
    projectID: ProjectID
  ) async throws -> ServiceTaskCreationResult {
    // Read-only submissions never occupy the project write slot, so they do
    // not take the Codex admission token.
    if request.permissionMode == .readOnly {
      do {
        return try await tasks.submit(request)
      } catch let storeError as ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
    }
    let admissionToken: String
    do {
      admissionToken = try await workspaceGate.beginCodexAdmission(projectID: projectID)
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      let result = try await tasks.submit(request)
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      return result
    } catch {
      await workspaceGate.endCodexAdmission(projectID: projectID, token: admissionToken)
      if let storeError = error as? ServiceStoreError {
        throw Self.publicStoreError(storeError)
      }
      throw error
    }
  }

  private func approveAndStartTask(_ taskID: TaskID) async throws {
    let started: ServiceTaskRecord
    do {
      started = try await tasks.approveAndBegin(taskID: taskID)
    } catch ServiceStoreError.invalidTaskTransition {
      throw BridgeMCPQueryError.approvalExpired
    } catch let storeError as ServiceStoreError {
      throw Self.publicStoreError(storeError)
    } catch {
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
    guard task.providerID == serviceCodexProviderID else {
      // Non-Codex providers do not advertise steer capability yet.
      throw BridgeMCPQueryError.invalidTaskState
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
    guard task.state.status == .running else {
      throw BridgeMCPQueryError.turnMismatch
    }
    if task.providerID != serviceCodexProviderID {
      guard let runID = task.state.providerRunID, runID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
      do {
        try await coordinator.interruptAgent(taskID: id, expectedRunID: expectedTurnID)
      } catch {
        throw Self.publicExecutionError(error)
      }
      return MCPServiceTaskMutationReceipt(
        taskID: taskID,
        status: task.state.status.rawValue,
        accepted: true
      )
    }
    guard task.state.codexTurnID == expectedTurnID else {
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
