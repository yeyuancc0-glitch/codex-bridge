import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPExecutionTests: XCTestCase {
  func testFailureDiagnosticsPreserveBoundedRemoteDetailsWithoutSecrets() {
    let message =
      "tool invocation failed; token=token-secret Authorization: Bearer bearer-secret "
      + "cookie=session-secret api_key=api-secret .env=env-secret "
      + #"{"password":"json-secret"} "#
      + String(repeating: " detail", count: 1_000)
    let summary = DeepSeekHarnessACPDiagnostic.failureSummary(
      for: DeepSeekHarnessACPError.remote(code: -32_602, message: message)
    )

    XCTAssertTrue(summary.contains("tool invocation failed"))
    XCTAssertTrue(summary.contains("-32602"))
    XCTAssertFalse(summary.contains("token-secret"))
    XCTAssertFalse(summary.contains("bearer-secret"))
    XCTAssertFalse(summary.contains("session-secret"))
    XCTAssertFalse(summary.contains("api-secret"))
    XCTAssertFalse(summary.contains("env-secret"))
    XCTAssertFalse(summary.contains("json-secret"))
    XCTAssertLessThanOrEqual(
      summary.utf8.count, DeepSeekHarnessACPDiagnostic.maximumProviderMessageBytes + 64)
  }

  func testFailureDiagnosticsIncludeProcessExitAndTransportReason() {
    XCTAssertTrue(
      DeepSeekHarnessACPDiagnostic.failureSummary(
        for: DeepSeekHarnessACPError.processExited(23)
      ).contains("exit code 23")
    )
    XCTAssertTrue(
      DeepSeekHarnessACPDiagnostic.failureSummary(
        for: DeepSeekHarnessACPError.transportClosed
      ).contains("transport closed")
    )
  }

  func testEOFRacePreservesTheUnderlyingProcessExitReason() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "eof-race-session"))
      case "session/prompt":
        await transport.finish(throwing: ACPError.processExited(23))
      default:
        break
      }
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "eof-race-installation"),
      providerSessionID: session.id,
      providerRunID: "eof-race-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "eof-race-task"), binding: binding),
      sessionID: session.id,
      prompt: "run",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      cleanup: {}
    )
    await execution.start()

    var events: [AgentEventEnvelope] = []
    for try await event in execution.events {
      events.append(event)
    }
    await client.shutdown()

    guard case .failed(let code, let summary) = events.last?.event else {
      return XCTFail("Expected a terminal failure")
    }
    XCTAssertEqual(code, "deepseek_harness_execution_failed")
    XCTAssertTrue(summary.contains("exit code 23"))
  }

  func testEndTurnEmitsAuthoritativeFinalAndCompletion() async throws {
    let events = try await runScenario(stopReason: "end_turn", text: "answer")
    XCTAssertEqual(events.count, 3)
    guard case .content(let delta) = events[0].event,
      case .content(let final) = events[1].event,
      case .completed(let summary, let stopReason) = events[2].event
    else {
      return XCTFail("Expected delta, authoritative final, and completion")
    }
    XCTAssertEqual(delta.mode, .delta)
    XCTAssertEqual(final.mode, .full)
    XCTAssertTrue(final.authoritative)
    XCTAssertEqual(final.content, "answer")
    XCTAssertEqual(summary, "answer")
    XCTAssertEqual(stopReason, "end_turn")
    XCTAssertEqual(events.map(\.providerSequence), [0, 1, 2])
  }

  func testRefusalAndMaxTokensAreFailures() async throws {
    for reason in ["refusal", "max_tokens"] {
      let events = try await runScenario(stopReason: reason, text: "partial")
      XCTAssertFalse(
        events.contains { event in
          if case .completed = event.event { return true }
          return false
        })
      guard case .failed(let code, _) = events.last?.event else {
        return XCTFail("Expected a stable failure for \(reason)")
      }
      XCTAssertEqual(code, "deepseek_harness_\(reason)")
    }
  }

  func testProviderCancellationWithoutLocalInterruptIsFailure() async throws {
    let events = try await runScenario(stopReason: "cancelled", text: "partial")

    XCTAssertFalse(
      events.contains { event in
        if case .interrupted = event.event { return true }
        return false
      })
    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected provider cancellation to fail")
    }
    XCTAssertEqual(code, "deepseek_harness_provider_cancelled")
  }

  func testStructuredExecutionEvidenceCompletesWithoutChangingPrompt() async throws {
    let events = try await runEvidenceScenario(text: "answer")

    guard case .completed(let summary, let stopReason) = events.last?.event else {
      return XCTFail("Expected a structured completion")
    }
    XCTAssertEqual(summary, "answer")
    XCTAssertEqual(stopReason, "end_turn")
  }

  func testMissingExecutionEvidenceFailsClosed() async throws {
    let events = try await runEvidenceScenario(text: "answer", includeExecutionEvidence: false)

    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected missing execution evidence to fail")
    }
    XCTAssertEqual(code, "deepseek_harness_execution_evidence_missing")
  }

  func testExecutionEvidenceMustMatchObservedToolLifecycle() async throws {
    let events = try await runEvidenceScenario(text: "answer", reportedToolCalls: 1)

    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected mismatched execution evidence to fail")
    }
    XCTAssertEqual(code, "deepseek_harness_execution_evidence_mismatch")
  }

  func testStructuredBlockedOutcomeFails() async throws {
    let events = try await runEvidenceScenario(text: "partial", outcome: "blocked")

    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected a blocked outcome to fail")
    }
    XCTAssertEqual(code, "deepseek_harness_blocked")
  }

  func testMatchingFailedToolEvidenceMayCompleteWhenHarnessOutcomeCompletes() async throws {
    let events = try await runEvidenceScenario(text: "fallback result", toolStatus: "failed")

    XCTAssertTrue(events.contains { if case .tool = $0.event { true } else { false } })
    guard case .completed(let summary, _) = events.last?.event else {
      return XCTFail("Expected Harness completed outcome to remain authoritative")
    }
    XCTAssertEqual(summary, "fallback result")
  }

  func testInterruptMapsToInterruptedAndSendsCancel() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let promptState = PromptRequestState()
    await transport.setHandler { message, transport in
      guard let id = message.id else {
        if message.method == "session/cancel" {
          if let promptID = await promptState.promptID() {
            try await transport.emit(
              ACPWireMessage(id: promptID, result: .object(["stopReason": .string("cancelled")]))
            )
          }
        }
        return
      }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "interrupt-session"))
      case "session/prompt":
        await promptState.set(id)
      default:
        break
      }
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "interrupt-installation"),
      providerSessionID: session.id,
      providerRunID: "interrupt-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "interrupt-task"), binding: binding),
      sessionID: session.id,
      prompt: "long task",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      cleanup: {}
    )
    await execution.start()
    try await Task.sleep(for: .milliseconds(50))
    try await execution.interrupt()
    var events: [AgentEventEnvelope] = []
    for try await event in execution.events {
      events.append(event)
    }
    XCTAssertTrue(
      events.contains {
        if case .interrupted = $0.event { return true }
        return false
      })
    let sent = await transport.sentMessages()
    XCTAssertTrue(sent.contains { $0.method == "session/cancel" })
  }

  private func runScenario(stopReason: String, text: String) async throws -> [AgentEventEnvelope] {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "execution-session"))
      case "session/prompt":
        try await transport.emit(
          deepSeekMessageChunk(sessionID: "execution-session", text: text)
        )
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string(stopReason)]))
        )
      default:
        break
      }
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "execution-installation"),
      providerSessionID: session.id,
      providerRunID: "execution-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "execution-task"), binding: binding),
      sessionID: session.id,
      prompt: "run",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      cleanup: {}
    )
    await execution.start()
    var events: [AgentEventEnvelope] = []
    for try await event in execution.events {
      events.append(event)
    }
    await client.shutdown()
    return events
  }

  private func runEvidenceScenario(
    text: String,
    toolStatus: String? = nil,
    includeExecutionEvidence: Bool = true,
    reportedToolCalls: Int? = nil,
    outcome: String = "completed"
  ) async throws -> [AgentEventEnvelope] {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "evidence-session"))
      case "session/prompt":
        let prompt = try XCTUnwrap(
          message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue
        )
        XCTAssertEqual(prompt, "run")
        if let toolStatus {
          try await transport.emit(
            deepSeekToolUpdate(
              sessionID: "evidence-session",
              updateType: "tool_call",
              toolCallID: "read-1",
              status: "in_progress",
              title: "read",
              kind: "read",
              rawInput: .object(["file_path": .string("AGENTS.md")])
            )
          )
          try await transport.emit(
            deepSeekToolUpdate(
              sessionID: "evidence-session",
              updateType: "tool_call_update",
              toolCallID: "read-1",
              status: toolStatus
            )
          )
        }
        try await transport.emit(
          deepSeekMessageChunk(sessionID: "evidence-session", text: text)
        )
        if includeExecutionEvidence {
          try await transport.emit(
            deepSeekPromptResult(
              id: id,
              outcome: outcome,
              toolCalls: reportedToolCalls ?? (toolStatus == nil ? 0 : 1),
              failedToolCalls: toolStatus == "failed" ? 1 : 0
            )
          )
        } else {
          try await transport.emit(deepSeekPromptResult(id: id))
        }
      default:
        break
      }
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "evidence-installation"),
      providerSessionID: session.id,
      providerRunID: "evidence-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "evidence-task"), binding: binding),
      sessionID: session.id,
      prompt: "run",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      requiresExecutionEvidence: true,
      cleanup: {}
    )
    await execution.start()
    var events: [AgentEventEnvelope] = []
    for try await event in execution.events {
      events.append(event)
    }
    await client.shutdown()
    return events
  }
}

private actor PromptRequestState {
  private var value: ACPRequestID?

  func set(_ id: ACPRequestID) {
    value = id
  }

  func promptID() -> ACPRequestID? {
    value
  }
}
