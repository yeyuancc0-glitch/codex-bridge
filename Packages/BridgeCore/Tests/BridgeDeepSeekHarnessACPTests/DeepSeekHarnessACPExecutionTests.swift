import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPExecutionTests: XCTestCase {
  func testCompletionPromptsContainExactAttestationMarkers() {
    let initial = DeepSeekHarnessACPCompletionAttestation.initialPrompt("run")
    XCTAssertTrue(initial.contains(DeepSeekHarnessACPCompletionAttestation.completedMarker))
    XCTAssertTrue(initial.contains(DeepSeekHarnessACPCompletionAttestation.failedMarker))
    XCTAssertTrue(
      DeepSeekHarnessACPCompletionAttestation.correctivePrompt.contains(
        DeepSeekHarnessACPCompletionAttestation.completedMarker
      )
    )
    XCTAssertTrue(
      DeepSeekHarnessACPCompletionAttestation.correctivePrompt.contains(
        DeepSeekHarnessACPCompletionAttestation.failedMarker
      )
    )
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

  func testAttestedShortResponseCompletesWithoutExposingMarker() async throws {
    let events = try await runAttestedScenario(
      texts: ["answer\n\(DeepSeekHarnessACPCompletionAttestation.completedMarker)"]
    )

    let finals = events.compactMap { event -> String? in
      guard case .content(let update) = event.event, update.authoritative else { return nil }
      return update.content
    }
    XCTAssertEqual(finals, ["answer"])
    guard case .completed(let summary, let stopReason) = events.last?.event else {
      return XCTFail("Expected an attested completion")
    }
    XCTAssertEqual(summary, "answer")
    XCTAssertEqual(stopReason, "end_turn")
  }

  func testUnattestedProviderResultGetsOneCorrectionThenFails() async throws {
    let events = try await runAttestedScenario(
      texts: ["工具调用格式出错，重新发起：", "工具调用格式出错，重新发起："]
    )

    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected an unattested result to fail")
    }
    XCTAssertEqual(code, "deepseek_harness_completion_unattested")
  }

  func testShortResponseCanCompleteAfterACompletionCorrection() async throws {
    let events = try await runAttestedScenario(
      texts: [
        "answer",
        "answer\n\(DeepSeekHarnessACPCompletionAttestation.completedMarker)",
      ]
    )

    XCTAssertTrue(events.contains { if case .completed = $0.event { true } else { false } })
    XCTAssertFalse(events.contains { if case .failed = $0.event { true } else { false } })
  }

  func testAttestedProviderFailureDoesNotComplete() async throws {
    let events = try await runAttestedScenario(
      texts: [
        "The required tool is unavailable.\n"
          + DeepSeekHarnessACPCompletionAttestation.failedMarker
      ]
    )

    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
    guard case .failed(let code, let summary) = events.last?.event else {
      return XCTFail("Expected an attested provider failure")
    }
    XCTAssertEqual(code, "deepseek_harness_provider_reported_failure")
    XCTAssertEqual(summary, "The required tool is unavailable.")
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

  private func runAttestedScenario(texts: [String]) async throws -> [AgentEventEnvelope] {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = AttestationPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "attestation-session"))
      case "session/prompt":
        let prompt = try XCTUnwrap(
          message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue
        )
        let count = await state.nextPrompt()
        if count == 1 {
          XCTAssertTrue(prompt.contains(DeepSeekHarnessACPCompletionAttestation.completedMarker))
          XCTAssertTrue(prompt.contains(DeepSeekHarnessACPCompletionAttestation.failedMarker))
        } else {
          XCTAssertEqual(prompt, DeepSeekHarnessACPCompletionAttestation.correctivePrompt)
        }
        let index = min(count - 1, texts.count - 1)
        try await transport.emit(
          deepSeekMessageChunk(sessionID: "attestation-session", text: texts[index])
        )
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
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
      installationID: .init(rawValue: "attestation-installation"),
      providerSessionID: session.id,
      providerRunID: "attestation-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "attestation-task"), binding: binding),
      sessionID: session.id,
      prompt: "run",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      requiresCompletionAttestation: true,
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

private actor AttestationPromptState {
  private var count = 0

  func nextPrompt() -> Int {
    count += 1
    return count
  }
}
