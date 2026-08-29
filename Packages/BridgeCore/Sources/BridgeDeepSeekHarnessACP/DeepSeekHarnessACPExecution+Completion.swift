import BridgeAgentCore

extension DeepSeekHarnessACPExecution {
  func nextPromptOrTerminal(stopReason: String) async throws -> String? {
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
        return try await completeAttestedTurn(content: summary, stopReason: stopReason)
      case .failed(let summary):
        return try await failAttestedTurn(content: summary)
      case .missing, .malformed:
        let finalizedContent = try await normalizer.finalizeContent()
        try emitFinalizedContent(finalizedContent)
        guard !terminal else { return nil }
        if interruptRequested {
          await finishInterrupted()
          return nil
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
    stopReason: String
  ) async throws -> String? {
    let finalizedContent = try await normalizer.finalizeContent(contentOverride: content)
    try emitFinalizedContent(finalizedContent)
    guard !terminal else { return nil }
    if interruptRequested {
      await finishInterrupted()
      return nil
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
}
