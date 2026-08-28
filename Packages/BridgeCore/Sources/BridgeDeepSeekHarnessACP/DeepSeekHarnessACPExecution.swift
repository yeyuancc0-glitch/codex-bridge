import BridgeAgentCore
import Foundation

public actor DeepSeekHarnessACPExecution {
  public nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>

  private let client: DeepSeekHarnessACPClient
  private let normalizer: DeepSeekHarnessACPEventNormalizer
  private let sessionID: String
  private let prompt: String
  private let initialClientEventSequence: Int64
  private let inactivityTimeout: Duration
  private let cleanup: @Sendable () -> Void
  private let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  private var eventTask: Task<Void, Never>?
  private var promptTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var consumedClientEventBarrier: Int64
  private var queuedSteers: [String] = []
  private var queuedSteerBytes = 0
  private var interruptRequested = false
  private var terminal = false

  private static let maximumQueuedSteers = 32
  private static let maximumQueuedSteerBytes = 256 * 1_024

  public init(
    client: DeepSeekHarnessACPClient,
    normalizer: DeepSeekHarnessACPEventNormalizer,
    sessionID: String,
    prompt: String,
    initialClientEventSequence: Int64,
    inactivityTimeout: Duration = DeepSeekHarnessACPConstants.inactivityTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer,
    cleanup: @escaping @Sendable () -> Void
  ) {
    let pair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.client = client
    self.normalizer = normalizer
    self.sessionID = sessionID
    self.prompt = prompt
    self.initialClientEventSequence = max(0, initialClientEventSequence)
    consumedClientEventBarrier = max(0, initialClientEventSequence)
    self.inactivityTimeout = inactivityTimeout
    self.cleanup = cleanup
    events = pair.stream
    continuation = pair.continuation
  }

  public func start() {
    guard eventTask == nil, promptTask == nil, !terminal else { return }
    let source = client.events
    eventTask = Task { [weak self] in
      guard let self else { return }
      for await envelope in source {
        await self.consume(envelope)
      }
      await self.clientEventsEnded()
    }
    promptTask = Task { [weak self] in
      await self?.runPrompt()
    }
    armWatchdog()
  }

  public func interrupt() async throws {
    guard !terminal else { throw AgentRuntimeError.processUnavailable }
    interruptRequested = true
    clearQueuedSteers()
    try await client.cancel(sessionID: sessionID)
  }

  /// ACP has no standard in-flight steer operation. Queue the input and send
  /// it as the next prompt on this same session after the current prompt
  /// resolves. The queue is bounded so control input cannot grow without
  /// limit while the Harness is busy.
  public func steer(text: String) throws {
    guard !terminal, !interruptRequested else {
      throw AgentRuntimeError.processUnavailable
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.utf8.count <= 64 * 1_024, !prompt.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("steer.text")
    }
    guard queuedSteers.count < Self.maximumQueuedSteers,
      queuedSteerBytes + prompt.utf8.count <= Self.maximumQueuedSteerBytes
    else {
      throw AgentRuntimeError.invalidRequest("steer.queue")
    }
    queuedSteers.append(prompt)
    queuedSteerBytes += prompt.utf8.count
  }

  public func resolveApproval(
    approvalID: String,
    optionID: String
  ) async throws {
    guard !terminal else { throw AgentRuntimeError.approvalUnavailable(approvalID) }
    try await client.resolvePermission(approvalID: approvalID, optionID: optionID)
  }

  public func shutdown() async {
    guard claimTerminal() else { return }
    interruptRequested = true
    clearQueuedSteers()
    try? await client.cancel(sessionID: sessionID)
    if let event = try? await normalizer.interrupted() {
      _ = emit(event)
    }
    await closeStream()
  }

  private func consume(_ envelope: DeepSeekHarnessACPClientEventEnvelope) async {
    guard !terminal else { return }
    armWatchdog()
    defer {
      consumedClientEventBarrier = max(consumedClientEventBarrier, envelope.sequence + 1)
    }
    guard envelope.sequence >= initialClientEventSequence else { return }
    do {
      if let normalized = try await normalizer.normalize(envelope), !emit(normalized) {
        await failStream(DeepSeekHarnessACPError.transportClosed)
      }
    } catch {
      await failExecution(
        code: "deepseek_harness_protocol_violation",
        summary: "DeepSeek Harness ACP sent an invalid task event."
      )
    }
  }

  private func clientEventsEnded() async {
    guard !terminal else { return }
    await failExecution(
      code: "deepseek_harness_eof_before_completion",
      summary: "DeepSeek Harness ACP ended before the task completed."
    )
  }

  private func runPrompt() async {
    do {
      var nextPrompt = prompt
      while true {
        if interruptRequested {
          await finishInterrupted()
          return
        }
        let result = try await client.prompt(sessionID: sessionID, text: nextPrompt)
        try await waitUntilConsumed(result.eventSequenceBarrier)
        guard !terminal else { return }
        if interruptRequested {
          await finishInterrupted()
          return
        }
        if result.stopReason == "cancelled" {
          await failExecution(
            code: "deepseek_harness_provider_cancelled",
            summary: "DeepSeek Harness cancelled the task without a local interrupt request."
          )
          return
        }
        if let queued = try await nextPromptOrTerminal(stopReason: result.stopReason) {
          nextPrompt = queued
          continue
        }
        return
      }
    } catch is CancellationError {
      guard !terminal else { return }
      if interruptRequested {
        await finishInterrupted()
      } else {
        await failExecution(
          code: "deepseek_harness_execution_cancelled",
          summary: "DeepSeek Harness execution was cancelled unexpectedly."
        )
      }
    } catch {
      guard !terminal else { return }
      await failExecution(
        code: "deepseek_harness_execution_failed",
        summary: Self.failureSummary(error)
      )
    }
  }

  private func nextPromptOrTerminal(stopReason: String) async throws -> String? {
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
    let finalizedContent = try await normalizer.finalizeContent()
    guard !terminal else { return nil }
    guard !finalizedContent.isEmpty else {
      await failExecution(
        code: "deepseek_harness_empty_response",
        summary: "DeepSeek Harness ACP completed without a committed assistant message."
      )
      return nil
    }

    do {
      for event in finalizedContent {
        guard emit(event) else { throw DeepSeekHarnessACPError.transportClosed }
      }
    } catch {
      await closeStream(throwing: error)
      return nil
    }

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

  private func waitUntilConsumed(_ barrier: Int64) async throws {
    while consumedClientEventBarrier < barrier {
      guard !terminal else { throw DeepSeekHarnessACPError.transportClosed }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func finishInterrupted() async {
    guard claimTerminal() else { return }
    if let interrupted = try? await normalizer.interrupted() {
      _ = emit(interrupted)
    }
    await closeStream()
  }

  private func dequeueSteer() -> String? {
    guard !queuedSteers.isEmpty else { return nil }
    let prompt = queuedSteers.removeFirst()
    queuedSteerBytes -= prompt.utf8.count
    return prompt
  }

  private func clearQueuedSteers() {
    queuedSteers.removeAll(keepingCapacity: false)
    queuedSteerBytes = 0
  }

  private func emit(_ event: AgentEventEnvelope) -> Bool {
    switch continuation.yield(event) {
    case .enqueued: true
    case .dropped, .terminated: false
    @unknown default: false
    }
  }

  private func failExecution(code: String, summary: String) async {
    guard claimTerminal() else { return }
    if let event = try? await normalizer.failed(code: code, summary: summary) {
      _ = emit(event)
    }
    await closeStream()
  }

  private func failStream(_ error: any Error) async {
    guard claimTerminal() else { return }
    await closeStream(throwing: error)
  }

  private func claimTerminal() -> Bool {
    guard !terminal else { return false }
    terminal = true
    clearQueuedSteers()
    return true
  }

  private func armWatchdog() {
    watchdogTask?.cancel()
    let timeout = inactivityTimeout
    watchdogTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await self?.inactivityTimedOut()
    }
  }

  private func inactivityTimedOut() async {
    try? await client.cancel(sessionID: sessionID)
    await failExecution(
      code: "deepseek_harness_inactivity_timeout",
      summary: "DeepSeek Harness produced no task activity before the local timeout."
    )
  }

  private func closeStream(throwing error: (any Error)? = nil) async {
    eventTask?.cancel()
    promptTask?.cancel()
    watchdogTask?.cancel()
    await client.shutdown()
    cleanup()
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  private static func failureSummary(_ error: any Error) -> String {
    switch error {
    case DeepSeekHarnessACPError.requestTimedOut:
      return "DeepSeek Harness ACP request timed out."
    case DeepSeekHarnessACPError.processExited:
      return "DeepSeek Harness ACP process exited before completion."
    case DeepSeekHarnessACPError.oversizedFrame:
      return "DeepSeek Harness ACP exceeded a protocol size limit."
    case DeepSeekHarnessACPError.sessionMismatch:
      return "DeepSeek Harness ACP reported an unexpected session."
    case DeepSeekHarnessACPError.remote(let code, _):
      return "DeepSeek Harness ACP returned protocol error \(code)."
    case DeepSeekHarnessACPError.inactivityTimeout:
      return "DeepSeek Harness ACP became inactive before completion."
    default:
      return "DeepSeek Harness ACP execution failed."
    }
  }
}
