import BridgeAgentCore
import Foundation

public actor OpenCodeACPExecution {
  public nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>

  private let client: OpenCodeACPClient
  private let normalizer: OpenCodeACPEventNormalizer
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
  private var interruptRequested = false
  private var terminal = false

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
    self.prompt = prompt
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
      let result = try await client.prompt(sessionID: sessionID, text: prompt)
      try await waitUntilConsumed(result.eventSequenceBarrier)
      guard !terminal else { return }
      let finalizedContent = try await normalizer.finalizeContent()
      let final: AgentEventEnvelope
      if result.stopReason == "cancelled" || interruptRequested {
        final = try await normalizer.interrupted()
      } else {
        final = try await normalizer.completed(stopReason: result.stopReason)
      }
      guard claimTerminal() else { return }
      for event in finalizedContent {
        guard emit(event) else {
          await closeStream(throwing: OpenCodeACPError.transportClosed)
          return
        }
      }
      guard emit(final) else {
        await closeStream(throwing: OpenCodeACPError.transportClosed)
        return
      }
      await closeStream()
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
