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
      ServiceAgentProviderPolicyRegistry.displayName(
        for: AgentProviderID(rawValue: providerID)
      )
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
    let eventLimit = min(max(recentEventLimit, 1), 6)
    let events = try await tasks.events(taskID: id, limit: eventLimit)
    let activityLimit = min(max(recentEventLimit, 1), 8)
    let activityMessages: [ServiceTaskMessageRecord]
    let recentActivityAvailable: Bool
    do {
      activityMessages = try await tasks.recentMessageActivity(taskID: id, limit: activityLimit)
      recentActivityAvailable = true
    } catch {
      activityMessages = []
      recentActivityAvailable = false
    }
    let recentActivity = activityMessages.enumerated().compactMap {
      taskActivity($0.element, sequence: Int64($0.offset + 1))
    }
    let isCodexProvider = task.providerID == serviceCodexProviderID
    let activityUpdatedAt =
      activityMessages
      .map(\.updatedAt)
      .max()
    let effectiveUpdatedAt = max(task.updatedAt, activityUpdatedAt ?? task.updatedAt)
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
      currentStep: task.state.currentStep.map {
        Self.safe($0, maximum: 2 * 1_024)
      },
      changedFiles: Self.boundedChangedFiles(task.state.changedFiles),
      recentEvents: events.map {
        MCPServiceTaskEvent(
          sequence: $0.id,
          kind: $0.kind.rawValue,
          summary: Self.safe($0.summary, maximum: 1_024),
          occurredAt: iso8601.string(from: $0.createdAt)
        )
      },
      recentActivity: recentActivity,
      recentActivityAvailable: recentActivityAvailable,
      supervisorStatus: task.state.supervisorStatus.rawValue,
      supervisorSummary: task.state.supervisorSummary.map {
        Self.safe($0, maximum: 8 * 1_024)
      },
      localApprovalRequired: task.state.status == .awaitingLocalApproval
        || task.state.status == .waitingForCodexApproval,
      resultSummary: task.state.resultSummary.map {
        Self.safe($0, maximum: 32 * 1_024)
      },
      failureCode: task.state.failureCode,
      updatedAt: iso8601.string(from: effectiveUpdatedAt)
    )
  }

  private func taskActivity(
    _ message: ServiceTaskMessageRecord,
    sequence: Int64
  ) -> MCPServiceTaskActivity? {
    let kind: String
    let summary: String
    let toolName: String?
    let toolStatus: String?
    switch message.kind {
    case .user:
      return nil
    case .agent:
      kind = "text"
      summary = message.content
      toolName = nil
      toolStatus = nil
    case .reasoning:
      kind = "reasoning"
      summary = message.content
      toolName = nil
      toolStatus = nil
    case .toolCall:
      kind = "tool_lifecycle"
      let name = message.toolName ?? "tool"
      let status = message.toolStatus ?? "in_progress"
      summary = name + " (" + status + ")"
      toolName = message.toolName
      toolStatus = message.toolStatus
    }
    return MCPServiceTaskActivity(
      sequence: sequence,
      kind: kind,
      summary: Self.safe(summary, maximum: 768),
      occurredAt: iso8601.string(from: message.updatedAt),
      toolName: toolName.map { Self.safe($0, maximum: 256) },
      toolStatus: toolStatus.map { Self.safe($0, maximum: 64) }
    )
  }

  private static func boundedChangedFiles(_ paths: [String]) -> [String] {
    let maximumTotalBytes = 16 * 1_024
    var result: [String] = []
    var usedBytes = 0
    for path in paths {
      let safePath = safe(path, maximum: 2 * 1_024)
      let byteCount = safePath.utf8.count
      guard byteCount > 0, usedBytes + byteCount <= maximumTotalBytes else { break }
      result.append(safePath)
      usedBytes += byteCount
    }
    return result
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
  /// installations. Provider-specific task constraints live in the shared
  /// service policy registry; adapter capabilities are checked by the runner.
  private func prepareAgentSubmission(
    _ submission: MCPServiceTaskSubmission,
    providerRaw: String,
    project: ServiceProjectRecord,
    sourceClientID: String
  ) async throws -> PreparedTaskSubmission {
    let providerID = AgentProviderID(rawValue: providerRaw)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.requiresInstallation
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard
      policy.supportsSupervisor
        || (submission.supervisorModel == nil && submission.supervisorEffort == nil)
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard policy.supportsSkillSelection || submission.skillName == nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard policy.supportsSessionContinuation || submission.threadID == nil else {
      throw BridgeMCPQueryError.contractRejected
    }

    let usesOverride = submission.modelOverride == true
    let requestedModel = usesOverride ? submission.executionModel : nil
    let requestedEffort = usesOverride ? submission.executionEffort : nil
    if !policy.supportsModelSelection && requestedModel != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if !policy.supportsEffortSelection && requestedEffort != nil {
      throw BridgeMCPQueryError.contractRejected
    }
    if let model = requestedModel {
      guard !model.isEmpty, model.utf8.count <= 256,
        model.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw BridgeMCPQueryError.contractRejected }
    }
    // A remote MCP model can fill optional tool arguments from its own safety
    // preference. Only a submission explicitly marked as a user-requested
    // override may replace persisted provider defaults. The nil case keeps
    // older in-process callers source-compatible; the MCP parser normalizes a
    // missing marker to false.
    let configuredModel: String?
    let configuredEffort: String?
    let defaultMode: ServicePermissionMode
    if policy.providerID == .openCode {
      configuredModel = try await settings.string(for: .openCodeDefaultModel)
      configuredEffort = try await settings.openCodeDefaultEffort()
      let configuredMode = try await settings.openCodeDefaultPermissionMode()
      defaultMode = configuredMode == "plan" ? .readOnly : .workspaceWrite
    } else if policy.providerID == .deepSeekHarness {
      configuredModel = try await settings.string(for: .deepSeekHarnessDefaultModel)
      configuredEffort = try await settings.string(for: .deepSeekHarnessDefaultEffort)
      defaultMode = policy.defaultPermissionMode
    } else {
      configuredModel = nil
      configuredEffort = nil
      defaultMode = policy.defaultPermissionMode
    }
    let resolvedModel = try Self.validatedAgentModel(requestedModel ?? configuredModel)
    if !policy.supportsWorkspaceWrite,
      submission.permissionMode == ServicePermissionMode.workspaceWrite.rawValue
    {
      throw BridgeMCPQueryError.contractRejected
    }
    let requestedPermissionMode =
      submission.permissionModeOverride == false ? nil : submission.permissionMode
    let permission = try Self.permissionMode(
      requestedPermissionMode,
      project: project,
      defaultMode: defaultMode
    )
    guard policy.supportsWorkspaceWrite || permission != .workspaceWrite else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard !submission.networkAccess || policy.allowsNetworkAccess else {
      // Provider policies never persist a requested network grant as though
      // the Bridge enforced it when the adapter has no task-level sandbox.
      throw BridgeMCPQueryError.unavailable
    }
    let registry = try requiredAgentRegistry()
    let selectable =
      try await registry.installations(providerID: providerID)
      .filter { $0.isSelectable }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    let record = try Self.selectAgentInstallation(
      requested: submission.installationID, from: selectable)
    if policy.supportsSessionContinuation, let requestedSessionID = submission.threadID {
      guard
        let previous = try await tasks.task(
          providerSessionID: requestedSessionID,
          providerID: providerID.rawValue,
          installationID: record.id.rawValue,
          projectID: project.id
        )
      else {
        throw BridgeMCPQueryError.taskNotFound
      }
      guard previous.state.status.isTerminal else {
        throw BridgeMCPQueryError.invalidTaskState
      }
    }
    let modelCatalog: [AgentModelDescriptor]?
    if policy.supportsModelSelection {
      modelCatalog = try? await serviceAgentModelCatalog(
        registry: registry,
        installationID: record.id,
        projectRoot: project.root.canonicalPath,
        selectedModelID: resolvedModel
      )
    } else {
      modelCatalog = nil
    }
    let selectedDescriptor: AgentModelDescriptor?
    if let modelCatalog {
      if let resolvedModel {
        selectedDescriptor = modelCatalog.first(where: { $0.id == resolvedModel })
      } else {
        selectedDescriptor = modelCatalog.first(where: {
          !$0.supportedReasoningEfforts.isEmpty
        })
      }
    } else {
      selectedDescriptor = nil
    }
    if policy.providerID == .deepSeekHarness, resolvedModel != nil, selectedDescriptor == nil {
      throw BridgeMCPQueryError.unavailable
    }
    let executionEffort: String
    if let requestedEffort {
      guard modelCatalog != nil else { throw BridgeMCPQueryError.unavailable }
      guard selectedDescriptor?.supportedReasoningEfforts.contains(requestedEffort) == true else {
        throw BridgeMCPQueryError.contractRejected
      }
      executionEffort = requestedEffort
    } else if let configuredEffort,
      selectedDescriptor?.supportedReasoningEfforts.contains(configuredEffort) == true
    {
      executionEffort = configuredEffort
    } else {
      executionEffort = serviceDefaultProviderExecutionEffort
    }
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
        requestedThreadID: submission.threadID,
        providerID: providerID.rawValue,
        installationID: record.id.rawValue,
        selectionMode: .explicit,
        executionModel: executionModel,
        executionEffort: executionEffort,
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
    guard task.state.status == .running else {
      throw BridgeMCPQueryError.turnMismatch
    }
    if task.providerID != serviceCodexProviderID {
      guard
        ServiceAgentProviderPolicyRegistry.policy(
          for: AgentProviderID(rawValue: task.providerID)
        )?.supportsSteer == true
      else {
        throw BridgeMCPQueryError.unavailable
      }
    }
    if task.providerID == serviceCodexProviderID {
      guard task.state.codexTurnID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
    } else {
      guard task.state.providerRunID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
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
