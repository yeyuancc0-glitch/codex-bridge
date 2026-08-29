import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPImmediateSteerTests: XCTestCase {
  func testImmediateSteerCancelsCurrentPromptAndContinuesSameSession() async throws {
    let fixture = try await makeFixture(includeQueuedFollowUp: true)
    for _ in 0..<100 {
      if await fixture.state.promptCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    try await fixture.execution.steer(text: "queued follow-up")
    try await fixture.execution.interruptCurrentThenSteer(text: "finish with current evidence")
    let events = try await collect(fixture.execution.events)
    let prompts = await fixture.state.prompts
    let sessionIDs = await fixture.state.sessionIDs
    let cancelPromptCounts = await fixture.state.cancelPromptCounts

    XCTAssertEqual(
      prompts,
      ["initial prompt", "finish with current evidence", "queued follow-up"]
    )
    XCTAssertEqual(sessionIDs, Array(repeating: "immediate-session", count: 3))
    XCTAssertEqual(cancelPromptCounts, [1, 3])
    XCTAssertFalse(events.contains { if case .interrupted = $0.event { true } else { false } })
    XCTAssertFalse(events.contains { if case .failed = $0.event { true } else { false } })
    guard case .completed(let summary, _) = events.last?.event else {
      return XCTFail("Expected completion after immediate correction")
    }
    XCTAssertEqual(summary, " response-3")
  }

  func testSecondImmediateSteerIsRejectedUntilCurrentCancellationSettles() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = ImmediateSteerState()
    await transport.setHandler { message, transport in
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: try XCTUnwrap(message.id)))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: try XCTUnwrap(message.id), sessionID: "immediate-session")
        )
      case "session/prompt":
        await state.recordPrompt(message)
      case "session/cancel":
        await state.recordCancel()
      default:
        break
      }
    }
    let execution = try await makeExecution(transport: transport)
    for _ in 0..<100 {
      if await state.promptCount > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    try await execution.interruptCurrentThenSteer(text: "first correction")
    do {
      try await execution.interruptCurrentThenSteer(text: "second correction")
      XCTFail("Expected a second immediate correction to be rejected")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("steer.immediate"))
    }
    await execution.shutdown()
    _ = try await collect(execution.events)
  }

  private func makeFixture(
    includeQueuedFollowUp _: Bool
  ) async throws -> (
    execution: DeepSeekHarnessACPExecution,
    state: ImmediateSteerState
  ) {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = ImmediateSteerState()
    await transport.setHandler { message, transport in
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: try XCTUnwrap(message.id)))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: try XCTUnwrap(message.id), sessionID: "immediate-session")
        )
      case "session/prompt":
        let count = await state.recordPrompt(message)
        guard count > 1 else { return }
        try await transport.emit(
          deepSeekMessageChunk(sessionID: "immediate-session", text: " response-\(count)")
        )
        try await transport.emit(
          ACPWireMessage(
            id: try XCTUnwrap(message.id),
            result: .object(["stopReason": .string("end_turn")])
          )
        )
      case "session/cancel":
        await state.recordCancel()
        let firstRequestIDValue = await state.firstRequestID
        try await transport.emit(
          ACPWireMessage(
            id: try XCTUnwrap(firstRequestIDValue),
            result: .object(["stopReason": .string("cancelled")])
          )
        )
      default:
        break
      }
    }
    return (try await makeExecution(transport: transport), state)
  }

  private func makeExecution(
    transport: ScriptedDeepSeekHarnessTransport
  ) async throws -> DeepSeekHarnessACPExecution {
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "immediate-installation"),
      providerSessionID: session.id,
      providerRunID: "immediate-run"
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: "immediate-task"), binding: binding),
      sessionID: session.id,
      prompt: "initial prompt",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      cleanup: {}
    )
    await execution.start()
    return execution
  }

  private func collect(
    _ stream: AsyncThrowingStream<AgentEventEnvelope, any Error>
  ) async throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    for try await event in stream { events.append(event) }
    return events
  }
}

private actor ImmediateSteerState {
  private(set) var prompts: [String] = []
  private(set) var sessionIDs: [String] = []
  private(set) var cancelPromptCounts: [Int] = []
  private(set) var firstRequestID: ACPRequestID?

  var promptCount: Int { prompts.count }

  @discardableResult
  func recordPrompt(_ message: ACPWireMessage) -> Int {
    prompts.append(message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? "")
    sessionIDs.append(message.params?["sessionId"]?.stringValue ?? "")
    if firstRequestID == nil { firstRequestID = message.id }
    return prompts.count
  }

  func recordCancel() {
    cancelPromptCounts.append(prompts.count)
  }
}
