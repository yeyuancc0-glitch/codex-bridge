import BridgeAgentCore
import Foundation

public actor OpenCodeACPExecution {
  public nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>

  private let client: OpenCodeACPClient
  private let normalizer: OpenCodeACPEventNormalizer
  private let sessionID: String
  private let initialPrompt: String
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
    client: OpenCodeACPClient,
    normalizer: OpenCodeACPEventNormalizer,
    sessionID: String,
    prompt: String,
    initialClientEventSequence: Int64,
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    cleanup: @escaping @Sendable () -> Void
  ) {
    let pair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.client = client
    self.normalizer = normalizer
    self.sessionID = sessionID
    self.initialPrompt = prompt
    self.initialClientEventSequence = max(0, initialClientEventSequence)
    self.inactivityTimeout = inactivityTimeout
    consumedClientEventBarrier = max(0, initialClientEventSequence)
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
    try await client.cancel(sessionID: sessionID)
  }

  /// ACP has no standard in-flight steer operation. Queue the input and send
  /// it as the next prompt on this same session after the current prompt
  /// resolves. Keeping this actor as the queue owner also serializes steer,
  /// completion, and interrupt races without a second control plane.
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
    try? await client.cancel(sessionID: sessionID)
    if let event = try? await normalizer.interrupted() {
      _ = emit(event)
    }
    await closeStream()
  }

  private func consume(_ envelope: OpenCodeACPClientEventEnvelope) async {
    guard !terminal else { return }
    armWatchdog()
    defer {
      consumedClientEventBarrier = max(consumedClientEventBarrier, envelope.sequence + 1)
    }
    guard envelope.sequence >= initialClientEventSequence else { return }
    do {
      if let normalized = try await normalizer.normalize(envelope.event), !emit(normalized) {
        await failStream(OpenCodeACPError.transportClosed)
      }
    } catch {
      await failExecution(
        code: "opencode_protocol_violation",
        summary: Self.failureSummary(error)
      )
    }
  }

  private func clientEventsEnded() async {
    guard !terminal else { return }
    await failExecution(
      code: "opencode_transport_closed",
      summary: "OpenCode ACP event stream closed before the turn completed."
    )
  }

  private func runPrompt() async {
    do {
      var prompt = initialPrompt
      while true {
        if interruptRequested {
          await finishInterrupted()
          return
        }
        let result = try await client.prompt(sessionID: sessionID, text: prompt)
        try await waitUntilConsumed(result.eventSequenceBarrier)
        guard !terminal else { return }
        if result.stopReason == "cancelled" || interruptRequested {
          await finishInterrupted()
          return
        }
        if let nextPrompt = try await nextPromptOrTerminal(stopReason: result.stopReason) {
          prompt = nextPrompt
          continue
        }
        return
      }
    } catch is CancellationError {
      guard claimTerminal() else { return }
      if let interrupted = try? await normalizer.interrupted() {
        _ = emit(interrupted)
      }
      await closeStream()
    } catch {
      guard !terminal else { return }
      await failExecution(
        code: "opencode_execution_failed",
        summary: Self.failureSummary(error)
      )
    }
  }

  private func nextPromptOrTerminal(stopReason: String) async throws -> String? {
    if let nextPrompt = dequeueSteer() {
      return nextPrompt
    }

    let finalizedContent = try await normalizer.finalizeContent()
    guard !terminal else { return nil }
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
      let final = try await normalizer.completed(stopReason: stopReason)
      for event in finalizedContent {
        guard emit(event) else {
          throw OpenCodeACPError.transportClosed
        }
      }
      guard emit(final) else {
        throw OpenCodeACPError.transportClosed
      }
      await closeStream()
    } catch {
      await closeStream(throwing: error)
    }
    return nil
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

  private func waitUntilConsumed(_ barrier: Int64) async throws {
    while consumedClientEventBarrier < barrier {
      guard !terminal else { throw OpenCodeACPError.transportClosed }
      try await Task.sleep(for: .milliseconds(5))
    }
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
      code: "opencode_inactivity_timeout",
      summary: "OpenCode produced no task activity before the local timeout."
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
    case OpenCodeACPError.requestTimedOut:
      return "OpenCode ACP request timed out."
    case OpenCodeACPError.processExited:
      return "OpenCode ACP process exited before completion."
    case OpenCodeACPError.oversizedFrame:
      return "OpenCode ACP exceeded a protocol size limit."
    case OpenCodeACPError.sessionMismatch:
      return "OpenCode ACP reported an unexpected session."
    case OpenCodeACPError.remote(let code, _):
      return "OpenCode ACP returned protocol error \(code)."
    default:
      return "OpenCode ACP execution failed."
    }
  }
}
