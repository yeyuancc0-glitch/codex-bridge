import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPExecutionTests: XCTestCase {
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
