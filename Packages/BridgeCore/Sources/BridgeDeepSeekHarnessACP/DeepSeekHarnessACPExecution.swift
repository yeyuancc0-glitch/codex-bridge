import BridgeAgentCore
import Foundation

public actor DeepSeekHarnessACPExecution {
  enum PromptPhase {
    case notStarted
    case running
    case settling
    case terminal
  }

  public nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>

  let client: DeepSeekHarnessACPClient
  let normalizer: DeepSeekHarnessACPEventNormalizer
  let sessionID: String
  private let prompt: String
  private let initialClientEventSequence: Int64
  private let inactivityTimeout: Duration
  let requiresExecutionEvidence: Bool
  private let cleanup: @Sendable () -> Void
  private let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  private var eventTask: Task<Void, Never>?
  private var promptTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var consumedClientEventBarrier: Int64
  var queuedSteers: [String] = []
  var queuedSteerBytes = 0
  var pendingImmediateSteer: String?
  var immediateCancelTask: Task<Void, any Error>?
  var promptPhase = PromptPhase.notStarted
  var interruptRequested = false
  var terminal = false

  static let maximumQueuedSteers = 32
  static let maximumQueuedSteerBytes = 256 * 1_024

  public init(
    client: DeepSeekHarnessACPClient,
    normalizer: DeepSeekHarnessACPEventNormalizer,
    sessionID: String,
    prompt: String,
    initialClientEventSequence: Int64,
    inactivityTimeout: Duration = DeepSeekHarnessACPConstants.inactivityTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer,
    requiresExecutionEvidence: Bool = false,
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
    self.requiresExecutionEvidence = requiresExecutionEvidence
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
    clearSteers()
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
      let normalized = try await normalizer.normalizeForExecution(envelope)
      for event in normalized {
        guard emit(event) else {
          await failStream(DeepSeekHarnessACPError.transportClosed)
          return
        }
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
    if let failure = await client.terminalFailure() {
      await failExecution(
        code: "deepseek_harness_execution_failed",
        summary: Self.failureSummary(failure)
      )
      return
    }
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
        let toolEvidenceBeforePrompt = await normalizer.toolEvidence()
        promptPhase = .running
        let result = try await client.prompt(sessionID: sessionID, text: nextPrompt)
        promptPhase = .settling
        try await waitUntilConsumed(result.eventSequenceBarrier)
        guard !terminal else { return }
        if interruptRequested {
          await finishInterrupted()
          return
        }
        let toolEvidenceAfterPrompt = await normalizer.toolEvidence()
        guard toolEvidenceAfterPrompt.calls >= toolEvidenceBeforePrompt.calls,
          toolEvidenceAfterPrompt.failedCalls >= toolEvidenceBeforePrompt.failedCalls,
          toolEvidenceAfterPrompt.unfinishedCalls == 0
        else {
          await failExecution(
            code: "deepseek_harness_protocol_violation",
            summary: "DeepSeek Harness reported inconsistent tool lifecycle evidence."
          )
          return
        }
        if result.stopReason == "cancelled" {
          if let immediate = try await resumeAfterImmediateSteer() {
            nextPrompt = immediate
            continue
          }
          await failExecution(
            code: "deepseek_harness_provider_cancelled",
            summary: "DeepSeek Harness cancelled the task without a local interrupt request."
          )
          return
        }
        if let queued = try await nextPromptOrTerminal(
          result: result,
          observedToolCalls: toolEvidenceAfterPrompt.calls - toolEvidenceBeforePrompt.calls,
          observedFailedToolCalls: toolEvidenceAfterPrompt.failedCalls
            - toolEvidenceBeforePrompt.failedCalls
        ) {
          promptPhase = .notStarted
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

  private func waitUntilConsumed(_ barrier: Int64) async throws {
    while consumedClientEventBarrier < barrier {
      guard !terminal else { throw DeepSeekHarnessACPError.transportClosed }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func finishInterrupted() async {
    guard claimTerminal() else { return }
    if let interrupted = try? await normalizer.interrupted() {
      _ = emit(interrupted)
    }
    await closeStream()
  }

  func emit(_ event: AgentEventEnvelope) -> Bool {
    switch continuation.yield(event) {
    case .enqueued: true
    case .dropped, .terminated: false
    @unknown default: false
    }
  }

  func failExecution(code: String, summary: String) async {
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

  func claimTerminal() -> Bool {
    guard !terminal else { return false }
    terminal = true
    promptPhase = .terminal
    clearSteers()
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

  func closeStream(throwing error: (any Error)? = nil) async {
    eventTask?.cancel()
    promptTask?.cancel()
    watchdogTask?.cancel()
    immediateCancelTask?.cancel()
    await client.shutdown()
    cleanup()
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  private static func failureSummary(_ error: any Error) -> String {
    DeepSeekHarnessACPDiagnostic.failureSummary(for: error)
  }
}
