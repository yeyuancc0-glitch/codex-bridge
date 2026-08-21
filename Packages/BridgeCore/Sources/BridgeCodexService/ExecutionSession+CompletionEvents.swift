import BridgeCodexRPC
import BridgeSecurity

extension ExecutionSession {
  func receiveTurnCompleted(_ notification: RPCNotification) async {
    do {
      guard case .turnCompleted(let completed) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("turn completed")
      }
      guard let binding else {
        guard deferredCompletion == nil else {
          throw ExecutionServiceError.protocolViolation("duplicate deferred completion")
        }
        deferredCompletion = completed
        return
      }
      guard completed.threadId == binding.threadID, completed.turn.id == binding.turnID else {
        throw ExecutionServiceError.bindingMismatch
      }
      await processTurnCompletion(completed)
    } catch {
      await fail(
        code: "invalid_turn_completed",
        summary: "Codex emitted an invalid Turn completion event."
      )
    }
  }

  func processTurnCompletion(_ completed: TurnNotification) async {
    guard let binding,
      completed.threadId == binding.threadID,
      completed.turn.id == binding.turnID
    else {
      await fail(code: "turn_binding_mismatch", summary: "Codex Turn completion did not match.")
      return
    }
    guard approvalBarriers.isEmpty, pendingApprovals.isEmpty else {
      guard deferredCompletion == nil else {
        await fail(
          code: "duplicate_turn_completion",
          summary: "Codex emitted duplicate Turn completion events."
        )
        return
      }
      deferredCompletion = completed
      return
    }

    let messages = Self.agentMessages(from: completed.turn)
    if !messages.isEmpty {
      yield(.turnCompleted(messages: messages))
    }

    switch completed.turn.status {
    case "completed":
      finish(with: .completed(resultSummary: Self.finalMessage(completed.turn)))
    case "interrupted":
      finish(with: .interrupted)
    case "failed":
      finish(
        with: .failed(
          code: "codex_turn_failed",
          summary: Self.turnFailureSummary(completed.turn)
        )
      )
    default:
      await fail(code: "invalid_turn_status", summary: "Codex reported an invalid terminal status.")
    }
  }

  func eventStreamEnded() async {
    guard !terminal else { return }
    await fail(
      code: "execution_stream_ended",
      summary: "The Codex execution event stream ended unexpectedly."
    )
  }

  func fail(code: String, summary: String) async {
    guard !terminal else { return }
    finish(with: .failed(code: code, summary: summary))
  }

  private func finish(with event: ExecutionEvent) {
    guard !terminal else { return }
    terminal = true
    _ = continuation.yield(event)
    continuation.finish()
    eventTask?.cancel()
    lifetimeTask?.cancel()
    Task { [client, onTermination, taskID] in
      await client.stop()
      await onTermination(taskID, self)
    }
  }

  func yield(_ event: ExecutionEvent) {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped, .terminated:
      Task {
        await self.fail(
          code: "execution_event_capacity",
          summary: "The Codex execution event capacity was exceeded."
        )
      }
    @unknown default:
      Task {
        await self.fail(
          code: "execution_event_capacity",
          summary: "The Codex execution event capacity was exceeded."
        )
      }
    }
  }

  func makeEvent(_ evidence: CodexSemanticExecutionEvidence) throws -> ExecutionEvent {
    switch evidence {
    case .planChanged(let plan):
      try requireActiveEvidence(threadID: plan.threadID, turnID: plan.turnID)
      let steps = plan.steps.map {
        OutboundContentSecurity.redacted($0.text, maximumUTF8Bytes: 4 * 1_024)
      }
      let currentStep =
        plan.steps.first(where: { $0.status == .inProgress })?.text
        ?? plan.steps.first(where: { $0.status == .pending })?.text
        ?? plan.steps.last?.text
        ?? plan.explanation
        ?? "Codex updated the task plan."
      return .planUpdated(
        currentStep: OutboundContentSecurity.redacted(
          currentStep,
          maximumUTF8Bytes: 4 * 1_024
        ),
        steps: steps
      )

    case .commandCompleted(let command):
      try requireKnownCompletedItem(command.item, type: "commandExecution")
      let status: ExecutionCommandStatus
      switch command.status {
      case .completed: status = .completed
      case .failed: status = .failed
      case .declined: status = .declined
      case .inProgress:
        throw ExecutionServiceError.protocolViolation("command completion status")
      }
      return .commandCompleted(
        displayCommand: OutboundContentSecurity.redacted(
          command.displayCommand,
          maximumUTF8Bytes: 8 * 1_024
        ),
        exitCode: command.exitCode,
        status: status
      )

    case .fileChangeCompleted(let file):
      try requireKnownCompletedItem(file.item, type: "fileChange")
      let status: ExecutionFileChangeStatus
      switch file.status {
      case .completed: status = .completed
      case .failed: status = .failed
      case .declined: status = .declined
      case .inProgress:
        throw ExecutionServiceError.protocolViolation("file completion status")
      }
      var paths: [String] = []
      for change in file.changes {
        paths.append(try ExecutionValidation.relativePath(change.path, root: projectRoot))
        if case .update(let movePath) = change.kind, let movePath {
          paths.append(try ExecutionValidation.relativePath(movePath, root: projectRoot))
        }
      }
      return .filesChanged(relativePaths: Array(Set(paths)).sorted(), status: status)
    }
  }

  func requireActiveEvidence(threadID: String, turnID: String) throws {
    guard threadID == expectedThreadID, startedTurnIDs.contains(turnID) else {
      throw ExecutionServiceError.bindingMismatch
    }
  }

  private func requireKnownCompletedItem(
    _ item: CodexApprovalItemKey,
    type: String
  ) throws {
    try requireActiveEvidence(threadID: item.threadID, turnID: item.turnID)
    guard seenItems[item] == type, knownItems[item] != nil else {
      throw ExecutionServiceError.protocolViolation("completed item")
    }
  }
}
