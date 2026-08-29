import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceExecutionCoordinator {
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

  func startAgentTask(
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
        interruptAndSteer: handle.interruptAndSteer,
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

      case .completed(let summary, let stopReason):
        try await finishAgentRun(taskID: taskID) {
          try await closeConversation(taskID: taskID)
          let current = try await requiredTask(taskID)
          return try await tasks.complete(
            taskID: taskID,
            resultSummary: summary.isEmpty ? "The agent run completed." : summary,
            changedFiles: current.state.changedFiles,
            eventSummary: Self.agentCompletionEventSummary(stopReason: stopReason)
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

  private static func agentCompletionEventSummary(stopReason: String?) -> String {
    guard let stopReason,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      stopReason.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return "The provider reported completion."
    }
    return "The provider reported completion with stop reason \(stopReason)."
  }
}
