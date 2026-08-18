import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

public actor ServiceExecutionCoordinator {
  private let tasks: ServiceTaskManager
  private let projects: ServiceProjectService
  private let execution: ExecutionManager
  private let supervisor: SupervisorManager?
  private let conversation: TaskConversationBuffer
  private var collectors: [TaskID: Task<Void, Never>] = [:]
  private var supervisorCollectors: [TaskID: Task<Void, Never>] = [:]

  public init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    execution: ExecutionManager,
    supervisor: SupervisorManager? = nil,
    conversation: TaskConversationBuffer? = nil
  ) {
    self.tasks = tasks
    self.projects = projects
    self.execution = execution
    self.supervisor = supervisor
    self.conversation = conversation ?? TaskConversationBuffer(tasks: tasks)
  }

  @discardableResult
  public func start(taskID: TaskID) async throws -> ExecutionBinding {
    guard collectors[taskID] == nil else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard let project = try await projects.project(id: task.projectID) else {
      throw ExecutionServiceError.projectUnavailable(task.projectID)
    }

    await launchSupervisor(for: task)
    let handle: ExecutionHandle
    do {
      handle = try await execution.start(try ExecutionRequest(task: task, project: project))
      _ = try await tasks.markExecutionStarted(
        taskID: taskID,
        threadID: handle.binding.threadID,
        turnID: handle.binding.turnID
      )
      await conversation.appendUserMessage(taskID: taskID, content: task.prompt)
    } catch {
      await execution.stop(taskID: taskID)
      await stopSupervisor(taskID: taskID)
      await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_start_failed",
        summary: "Codex could not start the task."
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
        approved: decision == .allow
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
    collectors.removeValue(forKey: taskID)?.cancel()
    await execution.stop(taskID: taskID)
    await stopSupervisor(taskID: taskID)
    await conversation.close(taskID: taskID)
    _ = try? await tasks.interrupt(taskID: taskID, summary: summary)
  }

  public func shutdown() async {
    let executionTasks = collectors.values
    let supervisorTasks = supervisorCollectors.values
    collectors.removeAll(keepingCapacity: false)
    supervisorCollectors.removeAll(keepingCapacity: false)
    for task in executionTasks { task.cancel() }
    for task in supervisorTasks { task.cancel() }
    await execution.shutdown()
    await supervisor?.shutdown()
    await conversation.closeAll()
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
        await conversation.close(taskID: taskID)

      case .interrupted:
        let interrupted = try await tasks.interrupt(
          taskID: taskID,
          summary: "Codex confirmed that the active Turn was interrupted."
        )
        await observeSupervisor(
          task: interrupted,
          kind: .final,
          summary: "Codex was interrupted before normal completion."
        )
        await conversation.close(taskID: taskID)

      case .failed(let code, let summary):
        let failed = try await tasks.fail(
          taskID: taskID,
          failureCode: code,
          summary: summary
        )
        await observeSupervisor(task: failed, kind: .final, summary: summary)
        await conversation.appendAgentMessage(taskID: taskID, content: summary)
        await conversation.close(taskID: taskID)
      }
    } catch {
      await execution.stop(taskID: taskID)
      await stopSupervisor(taskID: taskID)
      await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_state_update_failed",
        summary: Self.persistenceFailureSummary(error)
      )
    }
  }

  private static func persistenceFailureSummary(_ error: Error) -> String {
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
      return "The service could not persist Codex task progress."
    }
    return "The service could not persist Codex task progress: \(detail)"
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
