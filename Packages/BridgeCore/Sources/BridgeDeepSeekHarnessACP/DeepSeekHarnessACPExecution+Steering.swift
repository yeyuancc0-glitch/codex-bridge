import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPExecution {
  public func interrupt() async throws {
    guard !terminal else { throw AgentRuntimeError.processUnavailable }
    interruptRequested = true
    clearSteers()
    try await client.cancel(sessionID: sessionID)
  }

  /// Queue input for the next prompt on this session after the current prompt resolves.
  public func steer(text: String) throws {
    let prompt = try validatedSteer(text)
    try reserveSteer(prompt)
    queuedSteers.append(prompt)
    queuedSteerBytes += prompt.utf8.count
  }

  /// Cancel the current prompt without terminating the task, then send the
  /// corrective input as the next prompt on the same session.
  public func interruptCurrentThenSteer(text: String) async throws {
    let prompt = try validatedSteer(text)
    guard pendingImmediateSteer == nil else {
      throw AgentRuntimeError.invalidRequest("steer.immediate")
    }
    try reserveSteer(prompt)
    guard promptPhase == .running || promptPhase == .settling else {
      throw AgentRuntimeError.processUnavailable
    }
    pendingImmediateSteer = prompt
    guard promptPhase == .running else { return }

    let cancelTask = Task { try await client.cancel(sessionID: sessionID) }
    immediateCancelTask = cancelTask
    do {
      try await cancelTask.value
    } catch {
      if pendingImmediateSteer == prompt {
        pendingImmediateSteer = nil
        immediateCancelTask = nil
      }
      throw error
    }
  }

  func resumeAfterImmediateSteer() async throws -> String? {
    guard let prompt = pendingImmediateSteer else { return nil }
    try await immediateCancelTask?.value
    pendingImmediateSteer = nil
    immediateCancelTask = nil
    promptPhase = .notStarted
    for event in try await normalizer.finalizeContent() {
      guard emit(event) else { throw DeepSeekHarnessACPError.transportClosed }
    }
    return prompt
  }

  func dequeueSteer() -> String? {
    guard !queuedSteers.isEmpty else { return nil }
    let prompt = queuedSteers.removeFirst()
    queuedSteerBytes -= prompt.utf8.count
    return prompt
  }

  func clearSteers() {
    queuedSteers.removeAll(keepingCapacity: false)
    queuedSteerBytes = 0
    pendingImmediateSteer = nil
    immediateCancelTask?.cancel()
    immediateCancelTask = nil
  }

  private func validatedSteer(_ text: String) throws -> String {
    guard !terminal, !interruptRequested else {
      throw AgentRuntimeError.processUnavailable
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.utf8.count <= 64 * 1_024, !prompt.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("steer.text")
    }
    return prompt
  }

  private func reserveSteer(_ prompt: String) throws {
    let pendingCount = queuedSteers.count + (pendingImmediateSteer == nil ? 0 : 1)
    let pendingBytes = queuedSteerBytes + (pendingImmediateSteer?.utf8.count ?? 0)
    guard pendingCount < Self.maximumQueuedSteers,
      pendingBytes + prompt.utf8.count <= Self.maximumQueuedSteerBytes
    else {
      throw AgentRuntimeError.invalidRequest("steer.queue")
    }
  }
}
