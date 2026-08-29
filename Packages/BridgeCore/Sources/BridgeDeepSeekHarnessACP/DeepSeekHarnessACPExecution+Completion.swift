import BridgeAgentCore

extension DeepSeekHarnessACPExecution {
  func nextPromptOrTerminal(
    result: DeepSeekHarnessACPPromptResult,
    observedToolCalls: Int,
    observedFailedToolCalls: Int
  ) async throws -> String? {
    let stopReason = result.stopReason
    if requiresExecutionEvidence {
      guard let evidence = result.executionEvidence else {
        await failExecution(
          code: "deepseek_harness_execution_evidence_missing",
          summary: "DeepSeek Harness did not provide structured execution evidence."
        )
        return nil
      }
      guard evidence.toolCalls == observedToolCalls,
        evidence.failedToolCalls == observedFailedToolCalls
      else {
        await failExecution(
          code: "deepseek_harness_execution_evidence_mismatch",
          summary: "DeepSeek Harness execution metadata did not match its tool lifecycle events."
        )
        return nil
      }
      guard evidence.turnOutcome == .completed else {
        await failExecutionForOutcome(evidence.turnOutcome)
        return nil
      }
    }
    guard stopReason == "end_turn" else {
      switch stopReason {
      case "refusal":
        await failExecution(
          code: "deepseek_harness_refusal",
          summary: "DeepSeek Harness refused the task."
        )
      case "max_tokens":
        await failExecution(
          code: "deepseek_harness_max_tokens",
          summary: "DeepSeek Harness reached the model token limit before completion."
        )
      default:
        await failExecution(
          code: "deepseek_harness_unknown_stop_reason",
          summary: "DeepSeek Harness returned an unsupported stop reason."
        )
      }
      return nil
    }
    let content = await normalizer.currentContent()
    if requiresCompletionAttestation {
      switch DeepSeekHarnessACPCompletionAttestation.evaluate(content) {
      case .completed(let summary):
        return try await completeAttestedTurn(
          content: summary,
          stopReason: stopReason,
          observedToolCalls: observedToolCalls,
          observedFailedToolCalls: observedFailedToolCalls
        )
      case .failed(let summary):
        return try await failAttestedTurn(content: summary)
      case .missing, .malformed:
        if DeepSeekHarnessACPCompletionAttestation.reportsToolCallFailure(content) {
          recoveryRequiresSuccessfulToolCall = true
        }
        let finalizedContent = try await normalizer.finalizeContent()
        try emitFinalizedContent(finalizedContent)
        guard !terminal else { return nil }
        if interruptRequested {
          await finishInterrupted()
          return nil
        }
        if let immediate = try await resumeAfterImmediateSteer() {
          return immediate
        }
        if let nextPrompt = dequeueSteer() {
          return nextPrompt
        }
        guard !completionCorrectionSent else {
          await failExecution(
            code: "deepseek_harness_completion_unattested",
            summary: "DeepSeek Harness ended without a valid completion attestation."
          )
          return nil
        }
        completionCorrectionSent = true
        return DeepSeekHarnessACPCompletionAttestation.correctivePrompt
      }
    }

    let finalizedContent = try await normalizer.finalizeContent()
    return try await completeTurn(finalizedContent: finalizedContent, stopReason: stopReason)
  }

  private func completeAttestedTurn(
    content: String,
    stopReason: String,
    observedToolCalls: Int,
    observedFailedToolCalls: Int
  ) async throws -> String? {
    let finalizedContent = try await normalizer.finalizeContent(contentOverride: content)
    try emitFinalizedContent(finalizedContent)
    guard !terminal else { return nil }
    if interruptRequested {
      await finishInterrupted()
      return nil
    }
    if let immediate = try await resumeAfterImmediateSteer() {
      return immediate
    }
    if observedFailedToolCalls > 0
      || DeepSeekHarnessACPCompletionAttestation.reportsToolCallFailure(content)
    {
      recoveryRequiresSuccessfulToolCall = true
    }
    if recoveryRequiresSuccessfulToolCall {
      guard observedToolCalls > observedFailedToolCalls else {
        await failExecution(
          code: "deepseek_harness_tool_recovery_unverified",
          summary: "DeepSeek Harness did not complete a successful tool call after "
            + "reporting a tool-call failure."
        )
        return nil
      }
    }
    if let nextPrompt = dequeueSteer() {
      return nextPrompt
    }
    guard claimTerminal() else { return nil }
    do {
      let completed = try await normalizer.completed(stopReason: stopReason)
      guard emit(completed) else { throw DeepSeekHarnessACPError.transportClosed }
      await closeStream()
    } catch {
      await closeStream(throwing: error)
    }
    return nil
  }

  private func failAttestedTurn(content: String) async throws -> String? {
    let finalizedContent = try await normalizer.finalizeContent(contentOverride: content)
    try emitFinalizedContent(finalizedContent)
    await failExecution(
      code: "deepseek_harness_provider_reported_failure",
      summary: content.isEmpty
        ? "DeepSeek Harness reported that it could not complete the task."
        : content
    )
    return nil
  }

  private func completeTurn(
    finalizedContent: [AgentEventEnvelope],
    stopReason: String
  ) async throws -> String? {
    if let immediate = try await resumeAfterImmediateSteer() {
      return immediate
    }
    guard !finalizedContent.isEmpty else {
      await failExecution(
        code: "deepseek_harness_empty_response",
        summary: "DeepSeek Harness ACP completed without a committed assistant message."
      )
      return nil
    }

    try emitFinalizedContent(finalizedContent)

    if interruptRequested {
      await finishInterrupted()
      return nil
    }
    if let immediate = try await resumeAfterImmediateSteer() {
      return immediate
    }
    // A steer can arrive while the normalizer is finalizing the previous
    // turn. Re-check before claiming terminal so accepted input is never
    // lost to a completion race.
    if let nextPrompt = dequeueSteer() {
      return nextPrompt
    }
    guard claimTerminal() else { return nil }
    do {
      let completed = try await normalizer.completed(stopReason: stopReason)
      guard emit(completed) else { throw DeepSeekHarnessACPError.transportClosed }
      await closeStream()
    } catch {
      await closeStream(throwing: error)
    }
    return nil
  }

  private func emitFinalizedContent(_ events: [AgentEventEnvelope]) throws {
    for event in events {
      guard emit(event) else { throw DeepSeekHarnessACPError.transportClosed }
    }
  }

  private func failExecutionForOutcome(
    _ outcome: DeepSeekHarnessACPTurnOutcome
  ) async {
    let failure: (code: String, summary: String) =
      switch outcome {
      case .completed:
        (
          "deepseek_harness_execution_failed",
          "DeepSeek Harness returned inconsistent execution evidence."
        )
      case .blocked:
        ("deepseek_harness_blocked", "DeepSeek Harness could not continue the task.")
      case .aborted:
        ("deepseek_harness_aborted", "DeepSeek Harness aborted the task.")
      case .maxTokens:
        (
          "deepseek_harness_max_tokens",
          "DeepSeek Harness reached the model token limit before completion."
        )
      case .interrupted:
        (
          "deepseek_harness_provider_interrupted",
          "DeepSeek Harness reported an interrupted task without a local interrupt request."
        )
      case .cancelled:
        (
          "deepseek_harness_provider_cancelled",
          "DeepSeek Harness cancelled the task without a local interrupt request."
        )
      }
    await failExecution(code: failure.code, summary: failure.summary)
  }
}
