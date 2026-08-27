import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPQueuedSteerTests: XCTestCase {
  func testSteerQueuesFollowUpsInOrderOnTheSameSession() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = DeepSeekSteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "steer-session")
        )
      case "session/prompt":
        let prompt = try XCTUnwrap(Self.promptText(from: message))
        let count = await state.record(
          prompt: prompt,
          requestID: id,
          sessionID: try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        )
        guard count > 1 else { return }
        try await transport.emit(
          deepSeekMessageChunk(
            sessionID: "steer-session",
            text: " response-" + String(count)
          )
        )
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
        )
      default:
        break
      }
    }
    let fixture = try await makeExecution(
      transport: transport,
      state: state,
      taskID: "steer-task"
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await fixture.execution.steer(text: "first follow-up")
    try await fixture.execution.steer(text: "second follow-up")
    let firstRequestIDValue = await state.firstRequestID()
    let firstRequestID = try XCTUnwrap(firstRequestIDValue)
    try await transport.emit(deepSeekMessageChunk(sessionID: "steer-session", text: " initial"))
    try await transport.emit(
      ACPWireMessage(id: firstRequestID, result: .object(["stopReason": .string("end_turn")]))
    )

    let events = try await collect(fixture.execution.events)
    let prompts = await state.prompts
    let sessionIDs = await state.sessionIDs
    XCTAssertEqual(prompts, ["initial prompt", "first follow-up", "second follow-up"])
    XCTAssertEqual(sessionIDs, ["steer-session", "steer-session", "steer-session"])
    let finalUpdates = events.compactMap { event -> AgentContentUpdate? in
      guard case .content(let update) = event.event,
        update.mode == .full,
        update.authoritative
      else { return nil }
      return update
    }
    XCTAssertEqual(finalUpdates.count, 3)
    XCTAssertEqual(Set(finalUpdates.map(\.key)).count, 3)
    XCTAssertEqual(
      finalUpdates.map(\.content),
      [" initial", " response-2", " response-3"]
    )
    guard case .completed(let summary, _) = events.last?.event else {
      return XCTFail("Expected a final completion")
    }
    XCTAssertEqual(summary, " response-3")
    XCTAssertEqual(
      events.count(where: { if case .completed = $0.event { true } else { false } }), 1)
    XCTAssertEqual(
      events.count(where: { if case .interrupted = $0.event { true } else { false } }), 0)
  }

  func testEmptyTurnFailsBeforeDequeuingAQueuedFollowUp() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = DeepSeekSteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "empty-steer-session")
        )
      case "session/prompt":
        _ = await state.record(
          prompt: try XCTUnwrap(Self.promptText(from: message)),
          requestID: id,
          sessionID: try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        )
      default:
        break
      }
    }
    let fixture = try await makeExecution(
      transport: transport,
      state: state,
      taskID: "empty-steer-task"
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await fixture.execution.steer(text: "must not run")
    let firstRequestIDValue = await state.firstRequestID()
    let firstRequestID = try XCTUnwrap(firstRequestIDValue)
    try await transport.emit(
      ACPWireMessage(id: firstRequestID, result: .object(["stopReason": .string("end_turn")]))
    )

    let events = try await collect(fixture.execution.events)
    let prompts = await state.prompts
    XCTAssertEqual(prompts, ["initial prompt"])
    guard case .failed(let code, _) = events.last?.event else {
      return XCTFail("Expected an empty-turn failure")
    }
    XCTAssertEqual(code, "deepseek_harness_empty_response")
    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
  }

  func testInterruptDropsQueuedSteersAndEmitsOneInterrupted() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = DeepSeekSteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "interrupt-steer-session")
        )
      case "session/prompt":
        let prompt = try XCTUnwrap(Self.promptText(from: message))
        _ = await state.record(
          prompt: prompt,
          requestID: id,
          sessionID: try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        )
      default:
        break
      }
    }
    let fixture = try await makeExecution(
      transport: transport,
      state: state,
      taskID: "interrupt-steer-task"
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await fixture.execution.steer(text: "queued but cancelled")
    try await fixture.execution.steer(text: "also dropped")
    try await fixture.execution.interrupt()
    let firstRequestIDValue = await state.firstRequestID()
    let firstRequestID = try XCTUnwrap(firstRequestIDValue)
    try await transport.emit(
      ACPWireMessage(id: firstRequestID, result: .object(["stopReason": .string("cancelled")]))
    )

    let events = try await collect(fixture.execution.events)
    let prompts = await state.prompts
    XCTAssertEqual(prompts, ["initial prompt"])
    XCTAssertEqual(
      events.count(where: { if case .interrupted = $0.event { true } else { false } }), 1)
    XCTAssertEqual(
      events.count(where: { if case .completed = $0.event { true } else { false } }), 0)
    do {
      try await fixture.execution.steer(text: "after interrupt")
      XCTFail("Expected steer after interrupt to be rejected")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .processUnavailable)
    }
  }

  func testShutdownDropsQueuedSteersAndEmitsOneInterrupted() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = DeepSeekSteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "shutdown-steer-session")
        )
      case "session/prompt":
        _ = await state.record(
          prompt: try XCTUnwrap(Self.promptText(from: message)),
          requestID: id,
          sessionID: try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        )
      default:
        break
      }
    }
    let fixture = try await makeExecution(
      transport: transport,
      state: state,
      taskID: "shutdown-steer-task"
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await fixture.execution.steer(text: "queued before shutdown")
    await fixture.execution.shutdown()

    let events = try await collect(fixture.execution.events)
    let prompts = await state.prompts
    XCTAssertEqual(prompts, ["initial prompt"])
    XCTAssertEqual(
      events.count(where: { if case .interrupted = $0.event { true } else { false } }), 1)
    XCTAssertEqual(
      events.count(where: { if case .completed = $0.event { true } else { false } }), 0)
  }

  func testSteerRejectsInvalidTextAndAFullQueue() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let state = DeepSeekSteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "bounded-steer-session")
        )
      case "session/prompt":
        _ = await state.record(
          prompt: try XCTUnwrap(Self.promptText(from: message)),
          requestID: id,
          sessionID: try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        )
      default:
        break
      }
    }
    let fixture = try await makeExecution(
      transport: transport,
      state: state,
      taskID: "bounded-steer-task"
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    do {
      try await fixture.execution.steer(text: " \n")
      XCTFail("Expected blank steer input to be rejected")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("steer.text"))
    }
    for index in 0..<32 {
      try await fixture.execution.steer(text: "queued-" + String(index))
    }
    do {
      try await fixture.execution.steer(text: "overflow")
      XCTFail("Expected the steer queue limit to be enforced")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("steer.queue"))
    }
    await fixture.execution.shutdown()
    _ = try await collect(fixture.execution.events)
  }

  private func makeExecution(
    transport: ScriptedDeepSeekHarnessTransport,
    state _: DeepSeekSteerPromptState,
    taskID: String
  ) async throws -> (client: DeepSeekHarnessACPClient, execution: DeepSeekHarnessACPExecution) {
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: .init(rawValue: "steer-installation-" + taskID),
      providerSessionID: session.id,
      providerRunID: "steer-run-" + taskID
    )
    let execution = DeepSeekHarnessACPExecution(
      client: client,
      normalizer: .init(taskID: .init(rawValue: taskID), binding: binding),
      sessionID: session.id,
      prompt: "initial prompt",
      initialClientEventSequence: await client.eventSequence,
      inactivityTimeout: .seconds(30),
      cleanup: {}
    )
    await execution.start()
    return (client, execution)
  }

  private func collect(
    _ stream: AsyncThrowingStream<AgentEventEnvelope, any Error>
  ) async throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  private static func promptText(from message: ACPWireMessage) -> String? {
    message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue
  }
}

private actor DeepSeekSteerPromptState {
  private(set) var prompts: [String] = []
  private(set) var sessionIDs: [String] = []
  private var requestIDs: [ACPRequestID] = []

  var recordedPromptCount: Int { prompts.count }

  func record(prompt: String, requestID: ACPRequestID, sessionID: String) -> Int {
    prompts.append(prompt)
    requestIDs.append(requestID)
    sessionIDs.append(sessionID)
    return prompts.count
  }

  func firstRequestID() -> ACPRequestID? {
    requestIDs.first
  }
}
