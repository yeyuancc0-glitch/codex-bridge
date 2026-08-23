import BridgeCodexRPC
import BridgeSecurity

extension ExecutionSession {
  func receiveTurnCompleted(_ notification: RPCNotification) async {
    do {
      guard case .turnCompleted(let completed) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("turn completed")
      }
      let completedBinding = try ExecutionBinding(
        threadID: completed.threadId,
        turnID: completed.turn.id
      )
      guard isKnownBinding(completedBinding) else {
        throw ExecutionServiceError.bindingMismatch
      }
      if collaborationBindings.remove(completedBinding) != nil {
        guard Self.isTerminalTurnStatus(completed.turn.status) else {
          throw ExecutionServiceError.protocolViolation("collaboration turn status")
        }
        return
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
      await yield(.turnCompleted(messages: messages))
    }

    switch completed.turn.status {
    case "completed":
      await finish(with: .completed(resultSummary: Self.finalMessage(completed.turn)))
    case "interrupted":
      await finish(with: .interrupted)
    case "failed":
      await finish(
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
    let failure = await client.terminalFailure()
    await fail(
      code: Self.streamFailureCode(failure),
      summary: Self.streamFailureSummary(failure)
    )
  }

  private static func streamFailureCode(_ failure: CodexRPCError?) -> String {
    switch failure {
    case .processExited:
      "codex_process_exited"
    case .protocolLineTooLarge:
      "codex_protocol_line_too_large"
    case .transportReadOverflow, .eventBufferOverflow:
      "codex_transport_capacity"
    case .invalidUTF8, .malformedMessage, .protocolContamination:
      "codex_protocol_invalid"
    case nil:
      "execution_stream_ended"
    default:
      "codex_transport_failed"
    }
  }

  private static func streamFailureSummary(_ failure: CodexRPCError?) -> String {
    switch failure {
    case .processExited(let status):
      return "Codex app-server exited before the active Turn completed (status \(status))."
    case .protocolLineTooLarge(let maximumBytes):
      return "Codex app-server emitted a protocol message larger than \(maximumBytes) bytes."
    case .transportReadOverflow, .eventBufferOverflow:
      return "Codex app-server transport capacity was exceeded."
    case .invalidUTF8, .malformedMessage, .protocolContamination:
      return "Codex app-server emitted an invalid protocol message."
    case nil:
      return "The Codex execution event stream ended unexpectedly."
    default:
      return "The Codex app-server transport failed before the active Turn completed."
    }
  }

  func fail(code: String, summary: String) async {
    guard !terminal else { return }
    await finish(with: .failed(code: code, summary: summary))
  }

  private func finish(with event: ExecutionEvent) async {
    guard !terminal else { return }
    terminal = true
    await enqueue(event)
    continuation.finish()
    eventTask?.cancel()
    lifetimeTask?.cancel()
    Task { [client, onTermination, taskID] in
      await client.stop()
      await onTermination(taskID, self)
    }
  }

  func yield(_ event: ExecutionEvent) async {
    guard !terminal else { return }
    await enqueue(event)
  }

  private func enqueue(_ event: ExecutionEvent) async {
    while true {
      switch continuation.yield(event) {
      case .enqueued, .terminated:
        return
      case .dropped:
        do {
          try await Task.sleep(for: .milliseconds(1))
        } catch {
          return
        }
      @unknown default:
        return
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
    guard isKnownBinding(threadID: threadID, turnID: turnID) else {
      throw ExecutionServiceError.bindingMismatch
    }
  }

  static func isTerminalTurnStatus(_ status: String) -> Bool {
    status == "completed" || status == "interrupted" || status == "failed"
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
