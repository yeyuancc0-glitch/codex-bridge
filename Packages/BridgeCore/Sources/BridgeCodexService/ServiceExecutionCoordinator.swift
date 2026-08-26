import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

public actor ServiceExecutionCoordinator {
  private struct ActiveAgentRun: Sendable {
    let providerID: String
    let providerSessionID: String?
    let providerRunID: String?
    let effectiveRunID: String
    let interrupt: @Sendable () async throws -> Void
    let shutdown: @Sendable () async -> Void
    var lastSequence: Int64? = nil
  }

  private let tasks: ServiceTaskManager
  private let projects: ServiceProjectService
  private let execution: ExecutionManager
  private let supervisor: SupervisorManager?
  private let conversation: TaskConversationBuffer
  private let agentRunner: (any AgentTaskRunning)?
  private var collectors: [TaskID: Task<Void, Never>] = [:]
  private var supervisorCollectors: [TaskID: Task<Void, Never>] = [:]
  private var activeAgentRuns: [TaskID: ActiveAgentRun] = [:]
  private var finishedRuns: Set<TaskID> = []
  private var startingTasks: Set<TaskID> = []
  private var isShuttingDown = false

  public init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    execution: ExecutionManager,
    supervisor: SupervisorManager? = nil,
    conversation: TaskConversationBuffer? = nil,
    agentRunner: (any AgentTaskRunning)? = nil
  ) {
    self.tasks = tasks
    self.projects = projects
    self.execution = execution
    self.supervisor = supervisor
    self.conversation = conversation ?? TaskConversationBuffer(tasks: tasks)
    self.agentRunner = agentRunner
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

    await launchSupervisor(for: task)
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
      await stopSupervisor(taskID: taskID)
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

  public func pendingApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    await execution.pendingApprovals(taskID: taskID)
  }

  public func subscribeConversation(
    taskID: TaskID,
    limit: Int = 200
  ) async throws -> ConversationSubscription {
    guard try await tasks.task(id: taskID) != nil else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    let inMemory = await conversation.entries(taskID: taskID)
    let persistedLimit: Int
    if inMemory.count >= limit {
      persistedLimit = 0
    } else {
      persistedLimit = max(1, limit - inMemory.count)
    }
    let persisted = try await tasks.messages(taskID: taskID, limit: persistedLimit)
    let memoryKeys = Set(inMemory.map(\.key))
    var page =
      persisted
      .filter { !memoryKeys.contains($0.key) }
      .map {
        TaskConversationBuffer.Entry(
          key: $0.key,
          role: $0.role,
          kind: $0.kind,
          content: $0.content,
          toolName: $0.toolName,
          toolStatus: $0.toolStatus,
          toolArguments: $0.toolArguments,
          isFinal: true
        )
      }
    page.append(contentsOf: inMemory)
    let subscription = await conversation.subscribe(taskID: taskID)
    let merged =
      subscription.page.isEmpty
      ? page
      : page.filter { entry in
        !subscription.page.contains(where: { $0.key == entry.key })
      } + subscription.page
    return ConversationSubscription(
      subscriptionID: subscription.subscriptionID,
      page: Array(merged.suffix(limit)),
      updates: subscription.updates
    )
  }

  public func unsubscribeConversation(taskID: TaskID, subscriptionID: Int) async {
    await conversation.unsubscribe(taskID: taskID, subscriptionID: subscriptionID)
  }

  public func conversationPage(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) async throws -> [ServiceTaskMessageRecord] {
    guard try await tasks.task(id: taskID) != nil else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return try await tasks.messages(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  public func purgeConversation(taskID: TaskID) async {
    await conversation.purge(taskID: taskID)
  }

  public func resolveApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    try await execution.respondToApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision
    )
    do {
      let updated = try await tasks.resumeAfterCodexApproval(
        taskID: taskID,
        approved: decision.isApproval
      )
      await execution.finalizeApproval(
        taskID: taskID,
        approvalID: approvalID,
        committed: true
      )
      await observeSupervisor(
        task: updated,
        kind: .progress,
        summary: decision == .allow
          ? "The local user approved a Codex operation."
          : "The local user denied a Codex operation; Codex may choose a safer path."
      )
    } catch {
      await execution.finalizeApproval(
        taskID: taskID,
        approvalID: approvalID,
        committed: false
      )
      throw error
    }
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
    await stopSupervisor(taskID: taskID)
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
    let supervisorTasks = supervisorCollectors.values
    collectors.removeAll(keepingCapacity: false)
    supervisorCollectors.removeAll(keepingCapacity: false)
    for task in executionTasks { task.cancel() }
    for task in supervisorTasks { task.cancel() }
    let shutdowns = activeAgentRuns.values.map(\.shutdown)
    activeAgentRuns.removeAll(keepingCapacity: false)
    for shutdown in shutdowns {
      await shutdown()
    }
    await execution.shutdown()
    await supervisor?.shutdown()
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
        await observeSupervisor(
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
        await observeSupervisor(task: updated, kind: .progress, summary: summary)

      case .filesChanged(let relativePaths, let status):
        let changed = status == .completed ? relativePaths : []
        let summary =
          "Codex file change \(status.rawValue) for \(relativePaths.count) path(s)."
        let updated = try await tasks.recordChangedFiles(
          taskID: taskID,
          relativePaths: changed,
          summary: summary
        )
        await observeSupervisor(task: updated, kind: .progress, summary: summary)

      case .approvalRequested(let approval):
        let updated = try await tasks.markWaitingForCodexApproval(taskID: taskID)
        await observeSupervisor(
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
        await observeSupervisor(
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
        await observeSupervisor(
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
        await observeSupervisor(task: failed, kind: .final, summary: summary)
      }
    } catch {
      await execution.stop(taskID: taskID)
      await stopSupervisor(taskID: taskID)
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
        providerSessionID: handle.sessionID,
        providerRunID: handle.runID,
        effectiveRunID: runID,
        interrupt: handle.interrupt,
        shutdown: handle.shutdown
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
      case .content(let update):
        guard update.role == .assistant else { return }
        let kind: ServiceTaskMessageKind = update.kind == .reasoning ? .reasoning : .agent
        let bufferKey = Self.conversationPrefix(kind) + Self.agentItemKey(update.key)
        switch update.mode {
        case .delta:
          await conversation.appendDelta(
            taskID: taskID,
            itemID: Self.agentItemKey(update.key),
            delta: update.content,
            kind: kind
          )
        case .full:
          await conversation.upsertAuthoritativeEntry(
            taskID: taskID,
            key: bufferKey,
            kind: kind,
            content: update.content,
            isFinal: update.isFinal
          )
        }

      case .tool(let update):
        let itemID = Self.agentToolItemID(update.key)
        await conversation.upsertToolCall(
          taskID: taskID,
          call: try ExecutionToolCall(
            itemID: itemID,
            tool: update.name.isEmpty ? "tool" : update.name,
            arguments: update.arguments,
            status: Self.toolStatus(update.status)
          )
        )
        if update.status != .pending, update.status != .inProgress,
          let output = update.output, !output.isEmpty
        {
          await conversation.appendToolCallProgress(
            taskID: taskID,
            itemID: itemID,
            progress: output
          )
        }

      case .plan(let entries):
        let step =
          entries.first(where: { $0.status == nil || $0.status == "pending" })?
          .content ?? entries.last?.content
        if let currentStep = step.map(Self.boundedPlanStep) {
          _ = try await tasks.updatePlan(taskID: taskID, currentStep: currentStep)
        }

      case .usage:
        break

      case .approvalRequested(let approval):
        throw AgentRuntimeError.approvalUnavailable(approval.approvalID)

      case .approvalAutomaticallyDenied(let itemID):
        await conversation.upsertAuthoritativeEntry(
          taskID: taskID,
          key: "tool:" + itemID,
          kind: .toolCall,
          content: "The requested operation was denied by local policy.",
          toolStatus: ExecutionToolCallStatus.declined.rawValue,
          isFinal: false
        )

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

  static func conversationPrefix(_ kind: ServiceTaskMessageKind) -> String {
    switch kind {
    case .reasoning: "reasoning:"
    default: "agent:"
    }
  }

  /// Buffer delta keys are prefixed by kind; keep the provider stream key as a
  /// stable suffix so deltas and the final authoritative snapshot share one key.
  static func agentItemKey(_ key: String) -> String {
    var trimmed = Substring(key)
    for candidate in ["agent:", "reasoning:", "tool:", "user:"] where trimmed.hasPrefix(candidate) {
      trimmed = trimmed.dropFirst(candidate.count)
    }
    return trimmed.count > 256 ? String(trimmed.prefix(256)) : String(trimmed)
  }

  static func agentToolItemID(_ key: String) -> String {
    key.hasPrefix("tool:") ? String(key.dropFirst("tool:".count)) : key
  }

  static func toolStatus(_ status: AgentToolStatus) -> ExecutionToolCallStatus {
    switch status {
    case .pending, .inProgress: .inProgress
    case .completed: .completed
    case .failed: .failed
    case .cancelled, .declined: .declined
    }
  }

  static func boundedPlanStep(_ content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count > 512 else { return trimmed }
    return String(decoding: trimmed.utf8.prefix(512), as: UTF8.self)
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

  private func launchSupervisor(for task: ServiceTaskRecord) async {
    guard let supervisor else { return }
    do {
      guard let handle = try await supervisor.launch(task: task) else { return }
      let events = handle.events
      supervisorCollectors[task.id] = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          await self.consumeSupervisor(event, taskID: task.id)
        }
        await self?.supervisorCollectorFinished(task.id)
      }
    } catch {
      _ = try? await tasks.updateSupervisor(
        taskID: task.id,
        status: .degraded,
        summary: "Supervisor could not start; Codex execution continues."
      )
    }
  }

  private func consumeSupervisor(_ event: SupervisorEvent, taskID: TaskID) async {
    switch event {
    case .started:
      _ = try? await tasks.updateSupervisor(taskID: taskID, status: .running, summary: nil)

    case .decision(let decision):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: decision.summary
      )

    case .steer(let instruction, let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: summary
      )
      await applySupervisorSteer(taskID: taskID, instruction: instruction)

    case .attention(let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: summary
      )

    case .completed(let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .completed,
        summary: summary
      )

    case .degraded(_, let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .degraded,
        summary: summary
      )
    }
  }

  private func applySupervisorSteer(taskID: TaskID, instruction: String) async {
    do {
      let task = try await requiredTask(taskID)
      guard task.state.status == .running, let turnID = task.state.codexTurnID else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      try await execution.steer(
        taskID: taskID,
        expectedTurnID: turnID,
        text: instruction
      )
      await conversation.appendUserMessage(taskID: taskID, content: instruction)
    } catch {
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .degraded,
        summary: "Supervisor steer could not be applied; Codex execution continues."
      )
    }
  }

  private func observeSupervisor(
    task: ServiceTaskRecord,
    kind: SupervisorObservationKind,
    summary: String
  ) async {
    guard let supervisor else { return }
    let observation = try? SupervisorObservation(
      kind: kind,
      taskID: task.id,
      goal: task.prompt,
      currentStep: task.state.currentStep,
      summary: summary,
      changedFiles: task.state.changedFiles,
      resultSummary: task.state.resultSummary
    )
    guard let observation else {
      _ = try? await tasks.updateSupervisor(
        taskID: task.id,
        status: .degraded,
        summary: "Supervisor observation validation failed; Codex execution continues."
      )
      return
    }
    await supervisor.observe(observation)
  }

  private func stopSupervisor(taskID: TaskID) async {
    supervisorCollectors.removeValue(forKey: taskID)?.cancel()
    await supervisor?.stop(taskID: taskID)
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

  private func supervisorCollectorFinished(_ taskID: TaskID) {
    supervisorCollectors[taskID] = nil
  }
}
