import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

public actor ServiceExecutionCoordinator {
  struct ActiveAgentRun: Sendable {
    let providerID: String
    let installationID: String
    let providerSessionID: String?
    let providerRunID: String?
    let effectiveRunID: String
    let interrupt: @Sendable () async throws -> Void
    let steer: (@Sendable (String) async throws -> Void)?
    let shutdown: @Sendable () async -> Void
    let resolveApproval: (@Sendable (String, String) async throws -> Void)?
    var lastSequence: Int64? = nil
  }

  struct PendingAgentApproval: Sendable {
    let request: AgentApprovalRequest
    let createdAt: Date
  }

  let tasks: ServiceTaskManager
  let projects: ServiceProjectService
  let execution: ExecutionManager
  let supervision: ServiceSupervisorCoordinator
  let conversation: TaskConversationBuffer
  let conversationCoordinator: ServiceExecutionConversationCoordinator
  let agentEventProcessor: ServiceExecutionAgentEventProcessor
  let agentRunner: (any AgentTaskRunning)?
  let providerDisplayNameResolver: @Sendable (AgentProviderID) -> String
  private var collectors: [TaskID: Task<Void, Never>] = [:]
  var activeAgentRuns: [TaskID: ActiveAgentRun] = [:]
  var pendingAgentApprovals: [String: PendingAgentApproval] = [:]
  var finishedRuns: Set<TaskID> = []
  private var startingTasks: Set<TaskID> = []
  private var isShuttingDown = false
  let agentApprovalLifetime: TimeInterval = 5 * 60

  public init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    execution: ExecutionManager,
    supervisor: SupervisorManager? = nil,
    conversation: TaskConversationBuffer? = nil,
    agentRunner: (any AgentTaskRunning)? = nil,
    providerDisplayNameResolver: @escaping @Sendable (AgentProviderID) -> String = {
      if $0 == .codex { return "Codex" }
      if $0 == .openCode { return "OpenCode" }
      if $0 == .deepSeekHarness { return "DeepSeek Harness" }
      if $0 == .antigravity { return "Antigravity" }
      return $0.rawValue
    }
  ) {
    let conversation = conversation ?? TaskConversationBuffer(tasks: tasks)
    self.tasks = tasks
    self.projects = projects
    self.execution = execution
    self.supervision = ServiceSupervisorCoordinator(
      tasks: tasks,
      execution: execution,
      supervisor: supervisor,
      conversation: conversation
    )
    self.conversation = conversation
    self.conversationCoordinator = ServiceExecutionConversationCoordinator(
      tasks: tasks,
      conversation: conversation
    )
    self.agentEventProcessor = ServiceExecutionAgentEventProcessor(
      tasks: tasks,
      projects: projects,
      conversation: conversation
    )
    self.agentRunner = agentRunner
    self.providerDisplayNameResolver = providerDisplayNameResolver
  }

  @discardableResult
  public func start(taskID: TaskID) async throws -> ExecutionBinding? {
    guard !isShuttingDown else {
      throw ExecutionServiceError.processUnavailable
    }
    guard collectors[taskID] == nil, activeAgentRuns[taskID] == nil,
      startingTasks.insert(taskID).inserted
    else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    defer { startingTasks.remove(taskID) }
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard let project = try await projects.project(id: task.projectID) else {
      throw ExecutionServiceError.projectUnavailable(task.projectID)
    }
    guard task.providerID == serviceCodexProviderID else {
      try await startAgentTask(task, project: project)
      return nil
    }
    try ensureStartIsActive(taskID)

    await supervision.launch(task: task)
    let handle: ExecutionHandle
    do {
      handle = try await execution.start(try ExecutionRequest(task: task, project: project))
      try ensureStartIsActive(taskID)
      _ = try await tasks.markExecutionStarted(
        taskID: taskID,
        threadID: handle.binding.threadID,
        turnID: handle.binding.turnID
      )
      await conversation.appendUserMessage(taskID: taskID, content: task.prompt)
    } catch {
      await execution.stop(taskID: taskID)
      await supervision.stop(taskID: taskID)
      let conversationPersisted = await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: conversationPersisted
          ? "execution_start_failed" : "conversation_persistence_failed",
        summary: conversationPersisted
          ? "Codex could not start the task."
          : "The task conversation could not be persisted."
      )
      throw error
    }

    let events = handle.events
    collectors[taskID] = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.consume(event, taskID: taskID)
      }
      await self?.collectorFinished(taskID)
    }
    return handle.binding
  }

  public func steer(
    taskID: TaskID,
    expectedTurnID: String,
    text: String
  ) async throws {
    if let run = activeAgentRuns[taskID] {
      guard run.effectiveRunID == expectedTurnID else {
        throw ExecutionServiceError.bindingMismatch
      }
      guard let steer = run.steer else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      try await steer(text)
      await conversation.appendUserMessage(taskID: taskID, content: text)
      return
    }
    try await execution.steer(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      text: text
    )
    await conversation.appendUserMessage(taskID: taskID, content: text)
  }

  public func interrupt(
    taskID: TaskID,
    expectedTurnID: String? = nil
  ) async throws {
    try await execution.interrupt(taskID: taskID, expectedTurnID: expectedTurnID)
  }

  public func interruptAgent(taskID: TaskID, expectedRunID: String) async throws {
    guard let run = activeAgentRuns[taskID], run.effectiveRunID == expectedRunID else {
      throw ExecutionServiceError.threadMismatch(expectedRunID)
    }
    try await run.interrupt()
  }

  public func subscribeConversation(
    taskID: TaskID,
    limit: Int = 200
  ) async throws -> ConversationSubscription {
    try await conversationCoordinator.subscribe(taskID: taskID, limit: limit)
  }

  public func unsubscribeConversation(taskID: TaskID, subscriptionID: Int) async {
    await conversationCoordinator.unsubscribe(taskID: taskID, subscriptionID: subscriptionID)
  }

  public func conversationPage(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) async throws -> [ServiceTaskMessageRecord] {
    try await conversationCoordinator.page(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  public func liveConversationEntries(
    taskID: TaskID
  ) async throws -> [TaskConversationBuffer.Entry] {
    try await conversationCoordinator.liveEntries(taskID: taskID)
  }

  public func purgeConversation(taskID: TaskID) async {
    await conversationCoordinator.purge(taskID: taskID)
  }

  public func stop(
    taskID: TaskID,
    summary: String = "The local service stopped the task."
  ) async {
    startingTasks.remove(taskID)
    finishedRuns.insert(taskID)
    collectors.removeValue(forKey: taskID)?.cancel()
    await stopAgentRun(taskID: taskID)
    await execution.stop(taskID: taskID)
    await supervision.stop(taskID: taskID)
    if await conversation.close(taskID: taskID) {
      _ = try? await tasks.interrupt(taskID: taskID, summary: summary)
    } else {
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "conversation_persistence_failed",
        summary: "The task conversation could not be persisted."
      )
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    finishedRuns.formUnion(startingTasks)
    finishedRuns.formUnion(activeAgentRuns.keys)
    startingTasks.removeAll(keepingCapacity: false)
    let executionTasks = collectors.values
    collectors.removeAll(keepingCapacity: false)
    pendingAgentApprovals.removeAll(keepingCapacity: false)
    for task in executionTasks { task.cancel() }
    await supervision.beginShutdown()
    let shutdowns = activeAgentRuns.values.map(\.shutdown)
    activeAgentRuns.removeAll(keepingCapacity: false)
    for shutdown in shutdowns {
      await shutdown()
    }
    await execution.shutdown()
    await supervision.shutdown()
    let failedConversationTasks = await conversation.closeAll()
    for taskID in failedConversationTasks {
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "conversation_persistence_failed",
        summary: "The task conversation could not be persisted before service shutdown."
      )
    }
  }

  private func stopAgentRun(taskID: TaskID) async {
    finishedRuns.insert(taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    if let run = activeAgentRuns.removeValue(forKey: taskID) {
      await run.shutdown()
    }
  }

  private func ensureStartIsActive(_ taskID: TaskID) throws {
    guard !isShuttingDown, startingTasks.contains(taskID), !finishedRuns.contains(taskID) else {
      throw CancellationError()
    }
  }

  private func consume(_ event: ExecutionEvent, taskID: TaskID) async {
    do {
      switch event {
      case .planUpdated(let currentStep, let steps):
        let updated = try await tasks.updatePlan(taskID: taskID, currentStep: currentStep)
        await supervision.observe(
          task: updated,
          kind: .progress,
          summary: "Codex updated its plan with \(steps.count) step(s)."
        )

      case .commandCompleted(let displayCommand, let exitCode, let status):
        let exit = exitCode.map { " (exit \($0))" } ?? ""
        let summary = "Codex command \(status.rawValue)\(exit): \(displayCommand)"
        let updated = try await tasks.recordCommandCompletion(
          taskID: taskID,
          summary: summary
        )
        await supervision.observe(task: updated, kind: .progress, summary: summary)

      case .filesChanged(let relativePaths, let status):
        let changed = status == .completed ? relativePaths : []
        let summary =
          "Codex file change \(status.rawValue) for \(relativePaths.count) path(s)."
        let updated = try await tasks.recordChangedFiles(
          taskID: taskID,
          relativePaths: changed,
          summary: summary
        )
        await supervision.observe(task: updated, kind: .progress, summary: summary)

      case .approvalRequested(let approval):
        let updated = try await tasks.markWaitingForCodexApproval(taskID: taskID)
        await supervision.observe(
          task: updated,
          kind: .progress,
          summary: "Codex requested local approval for \(approval.kind.rawValue)."
        )

      case .agentMessageDelta(let delta):
        await conversation.appendDelta(taskID: taskID, itemID: delta.itemID, delta: delta.delta)

      case .reasoningDelta(let delta):
        await conversation.appendDelta(
          taskID: taskID,
          itemID: delta.itemID,
          delta: delta.delta,
          kind: .reasoning
        )

      case .toolCall(let call):
        await conversation.upsertToolCall(taskID: taskID, call: call)

      case .toolCallProgress(let itemID, let progress):
        await conversation.appendToolCallProgress(
          taskID: taskID, itemID: itemID, progress: progress)

      case .turnCompleted(let messages):
        await conversation.finalize(taskID: taskID, messages: messages)

      case .completed(let resultSummary):
        try await closeConversation(taskID: taskID)
        let current = try await requiredTask(taskID)
        let completed = try await tasks.complete(
          taskID: taskID,
          resultSummary: resultSummary,
          changedFiles: current.state.changedFiles
        )
        await supervision.observe(
          task: completed,
          kind: .final,
          summary: "Codex completed the task."
        )

      case .interrupted:
        try await closeConversation(taskID: taskID)
        let interrupted = try await tasks.interrupt(
          taskID: taskID,
          summary: "Codex confirmed that the active Turn was interrupted."
        )
        await supervision.observe(
          task: interrupted,
          kind: .final,
          summary: "Codex was interrupted before normal completion."
        )

      case .failed(let code, let summary):
        await conversation.appendAgentMessage(taskID: taskID, content: summary)
        try await closeConversation(taskID: taskID)
        let failed = try await tasks.fail(
          taskID: taskID,
          failureCode: code,
          summary: summary
        )
        await supervision.observe(task: failed, kind: .final, summary: summary)
      }
    } catch {
      await execution.stop(taskID: taskID)
      await supervision.stop(taskID: taskID)
      _ = await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_state_update_failed",
        summary: Self.persistenceFailureSummary(error)
      )
    }
  }

  private static func agentStartFailureSummary(_ error: Error, provider: String) -> String {
    if case AgentRuntimeError.modelUnavailable(let model) = error {
      let value = String(model.prefix(256))
      return
        "The selected \(provider) model is unavailable: \(value). Refresh the model list and choose an available model."
    }
    var detail = String(describing: error)
    if detail.count > 300 { detail = String(detail.prefix(300)) }
    detail =
      detail
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return "The \(provider) agent could not start the task: \(detail)"
  }

  private static func agentStartFailureCode(_ error: Error) -> String {
    if case AgentRuntimeError.modelUnavailable = error {
      return "agent_model_unavailable"
    }
    return "agent_start_failed"
  }

  private func startAgentTask(
    _ task: ServiceTaskRecord,
    project: ServiceProjectRecord
  ) async throws {
    guard let runner = agentRunner else {
      throw ExecutionServiceError.processUnavailable
    }
    guard let installationID = task.installationID else {
      throw ExecutionServiceError.invalidRequest("installationID")
    }
    let brief = AgentTaskBrief(
      taskID: task.id,
      providerID: AgentProviderID(rawValue: task.providerID),
      installationID: AgentInstallationID(rawValue: installationID),
      projectID: task.projectID,
      projectRoot: project.root.canonicalPath,
      prompt: task.prompt,
      requestedSessionID: task.requestedThreadID,
      model: task.executionModel == serviceDefaultProviderExecutionModel
        ? nil : task.executionModel,
      effort: task.executionEffort == serviceDefaultProviderExecutionEffort
        ? nil : task.executionEffort,
      permissionMode: task.permissionMode,
      networkAllowed: task.networkAllowed
    )
    let handle: AgentTaskRunHandle
    do {
      handle = try await runner.start(brief)
    } catch {
      if !finishedRuns.contains(task.id), !isShuttingDown {
        let conversationPersisted = await conversation.close(taskID: task.id)
        _ = try? await tasks.fail(
          taskID: task.id,
          failureCode: conversationPersisted
            ? Self.agentStartFailureCode(error) : "conversation_persistence_failed",
          summary: conversationPersisted
            ? Self.agentStartFailureSummary(error, provider: task.providerID)
            : "The task conversation could not be persisted."
        )
      }
      throw error
    }

    do {
      try ensureStartIsActive(task.id)
      let runID =
        handle.runID.flatMap { $0.isEmpty ? nil : $0 }
        ?? UUID().uuidString.lowercased()
      // The state model pairs session/run; when the provider has no stable
      // session concept the run identity doubles as the session reference.
      let sessionID = handle.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? runID
      _ = try await tasks.markAgentExecutionStarted(
        taskID: task.id,
        providerSessionID: sessionID,
        providerRunID: runID
      )
      activeAgentRuns[task.id] = ActiveAgentRun(
        providerID: task.providerID,
        installationID: installationID,
        providerSessionID: handle.sessionID,
        providerRunID: handle.runID,
        effectiveRunID: runID,
        interrupt: handle.interrupt,
        steer: handle.steer,
        shutdown: handle.shutdown,
        resolveApproval: handle.resolveApproval
      )
      await conversation.appendUserMessage(taskID: task.id, content: task.prompt)
      try ensureStartIsActive(task.id)
    } catch {
      activeAgentRuns.removeValue(forKey: task.id)
      await handle.shutdown()
      if !finishedRuns.contains(task.id), !isShuttingDown {
        let conversationPersisted = await conversation.close(taskID: task.id)
        _ = try? await tasks.fail(
          taskID: task.id,
          failureCode: conversationPersisted
            ? Self.agentStartFailureCode(error) : "conversation_persistence_failed",
          summary: conversationPersisted
            ? Self.agentStartFailureSummary(error, provider: task.providerID)
            : "The task conversation could not be persisted."
        )
      }
      throw error
    }

    let events = handle.events
    collectors[task.id] = Task { [weak self] in
      do {
        for try await envelope in events {
          guard let self else { return }
          await self.consumeAgent(envelope, taskID: task.id)
        }
        await self?.agentStreamFinished(task.id, failure: nil)
      } catch {
        await self?.agentStreamFinished(task.id, failure: error)
      }
    }
  }

  private func consumeAgent(_ envelope: AgentEventEnvelope, taskID: TaskID) async {
    guard !finishedRuns.contains(taskID) else { return }
    do {
      try validateAgentEnvelope(envelope, taskID: taskID)
      switch envelope.event {
      case .content, .tool, .plan, .usage, .approvalAutomaticallyDenied:
        try await agentEventProcessor.process(envelope.event, taskID: taskID)

      case .approvalRequested(let approval):
        _ = try await registerAgentApproval(approval, taskID: taskID)

      case .completed(let summary, _):
        try await finishAgentRun(taskID: taskID) {
          try await closeConversation(taskID: taskID)
          let current = try await requiredTask(taskID)
          return try await tasks.complete(
            taskID: taskID,
            resultSummary: summary.isEmpty ? "The agent run completed." : summary,
            changedFiles: current.state.changedFiles
          )
        }

      case .interrupted:
        try await finishAgentRun(taskID: taskID) {
          try await closeConversation(taskID: taskID)
          return try await tasks.interrupt(
            taskID: taskID,
            summary: "The agent confirmed that the run was interrupted."
          )
        }

      case .failed(let code, let summary):
        try await finishAgentRun(taskID: taskID) {
          await conversation.appendAgentMessage(taskID: taskID, content: summary)
          try await closeConversation(taskID: taskID)
          return try await tasks.fail(
            taskID: taskID,
            failureCode: code,
            summary: summary
          )
        }
      }
    } catch {
      finishedRuns.insert(taskID)
      pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
      if let run = activeAgentRuns.removeValue(forKey: taskID) {
        await run.shutdown()
      }
      _ = await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "agent_execution_failed",
        summary: Self.persistenceFailureSummary(error, provider: envelope.providerID.rawValue)
      )
    }
  }

  private func finishAgentRun(
    taskID: TaskID,
    transition: () async throws -> ServiceTaskRecord?
  ) async throws {
    guard !finishedRuns.contains(taskID) else { return }
    finishedRuns.insert(taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    let run = activeAgentRuns.removeValue(forKey: taskID)
    do {
      _ = try await transition()
    } catch {
      if let run { await run.shutdown() }
      throw error
    }
    if let run { await run.shutdown() }
  }

  private func agentStreamFinished(_ taskID: TaskID, failure: (any Error)?) async {
    collectors.removeValue(forKey: taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    guard finishedRuns.remove(taskID) == nil else { return }
    if let run = activeAgentRuns.removeValue(forKey: taskID) {
      await run.shutdown()
    }
    _ = await conversation.close(taskID: taskID)
    let summary: String
    let failureCode: String
    if let failure {
      failureCode = "agent_execution_failed"
      summary = Self.persistenceFailureSummary(failure, provider: "agent")
    } else {
      failureCode = "agent_stream_ended"
      summary = "The agent event stream ended before reporting a terminal result."
    }
    _ = try? await tasks.fail(
      taskID: taskID,
      failureCode: failureCode,
      summary: summary
    )
  }

  private func validateAgentEnvelope(
    _ envelope: AgentEventEnvelope,
    taskID: TaskID
  ) throws {
    guard var run = activeAgentRuns[taskID] else {
      throw AgentRuntimeError.runMismatch
    }
    guard envelope.taskID == taskID,
      envelope.providerID.rawValue == run.providerID,
      envelope.providerSessionID == run.providerSessionID,
      envelope.providerRunID == run.providerRunID,
      run.lastSequence.map({ envelope.providerSequence > $0 }) ?? true
    else {
      throw AgentRuntimeError.malformedEvent("agent.binding")
    }
    run.lastSequence = envelope.providerSequence
    activeAgentRuns[taskID] = run
  }

  private func closeConversation(taskID: TaskID) async throws {
    guard await conversation.close(taskID: taskID) else {
      throw ExecutionServiceError.conversationPersistenceFailed
    }
  }

  private static func persistenceFailureSummary(_ error: Error, provider: String = "Codex")
    -> String
  {
    let source = String(describing: error)
    let characters = source.unicodeScalars.map { scalar -> Character in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D:
        Character(scalar)
      case 0..<0x20, 0x7F:
        " "
      default:
        Character(scalar)
      }
    }
    let sanitized = String(characters)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    let detail = sanitized.prefix(512)
    guard !detail.isEmpty else {
      return "The service could not persist \(provider) task progress."
    }
    return "The service could not persist \(provider) task progress: \(detail)"
  }

  private func requiredTask(_ taskID: TaskID) async throws -> ServiceTaskRecord {
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return task
  }

  private func collectorFinished(_ taskID: TaskID) {
    collectors[taskID] = nil
  }
}
