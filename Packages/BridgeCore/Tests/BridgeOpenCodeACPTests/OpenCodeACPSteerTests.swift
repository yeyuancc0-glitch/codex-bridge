import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPSteerTests: XCTestCase {
  func testSteerQueuesNextPromptOnTheSameSession() async throws {
    let transport = ScriptedACPTransport()
    let state = SteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.initializationResult())
        )
      case "session/new":
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.sessionResult())
        )
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["configOptions": Self.sessionConfigOptions()])
          )
        )
      case "session/prompt":
        let prompt = try XCTUnwrap(Self.promptText(from: message))
        let sessionID = try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        let promptNumber = await state.record(
          prompt: prompt,
          requestID: id,
          sessionID: sessionID
        )
        guard promptNumber > 1 else { return }
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.messageUpdate(text: "The steer was applied.", messageID: "steer")
          )
        )
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
        )
      default:
        break
      }
    }

    let projectRoot = try makeTemporaryDirectory(prefix: "opencode-steer-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "opencode-steer-home")
    let runtimeBase = temporaryPath(prefix: "opencode-steer-runtime")
    addTeardownBlock {
      for path in [projectRoot, sourceHome, runtimeBase] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-opencode-steer"),
      projectID: ProjectID(rawValue: "project-opencode-steer"),
      projectRoot: projectRoot,
      prompt: "Inspect the repository.",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false,
      requiredCapabilities: [.sessionCreate, .steer]
    )
    let handle = try await provider.start(
      request,
      installation: try AgentInstallation(
        id: AgentInstallationID(rawValue: "installation-opencode-steer"),
        providerID: .openCode,
        executablePath: "/bin/echo"
      )
    )
    XCTAssertTrue(handle.capabilities.effective.contains(.steer))

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let steer = try XCTUnwrap(handle.control.steer)
    try await steer("Focus on the failing test.")

    let firstRequestIDValue = await state.takeFirstRequestID()
    let firstRequestID = try XCTUnwrap(firstRequestIDValue)
    try await transport.emit(
      ACPWireMessage(id: firstRequestID, result: .object(["stopReason": .string("end_turn")]))
    )

    var events: [AgentEventEnvelope] = []
    for try await event in handle.events {
      events.append(event)
    }

    let prompts = await transport.sentMessages()
      .filter { $0.method == "session/prompt" }
      .compactMap(Self.promptText(from:))
    XCTAssertEqual(prompts, ["Inspect the repository.", "Focus on the failing test."])
    let sessionIDs = await state.sessionIDs
    XCTAssertEqual(sessionIDs, ["session-steer", "session-steer"])
    XCTAssertTrue(
      events.contains { envelope in
        guard case .content(let update) = envelope.event else { return false }
        return update.content == "The steer was applied."
      }
    )
    XCTAssertTrue(events.contains { if case .completed = $0.event { true } else { false } })
    do {
      try await steer("This must be rejected after completion.")
      XCTFail("Expected steer after terminal completion to be rejected")
    } catch {
      XCTAssertEqual(error as? AgentRuntimeError, .processUnavailable)
    }
  }

  func testInterruptDropsQueuedSteerBeforeStartingAnotherPrompt() async throws {
    let transport = ScriptedACPTransport()
    let state = SteerPromptState()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.initializationResult())
        )
      case "session/new":
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.sessionResult())
        )
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["configOptions": Self.sessionConfigOptions()])
          )
        )
      case "session/prompt":
        let prompt = try XCTUnwrap(Self.promptText(from: message))
        let sessionID = try XCTUnwrap(message.params?["sessionId"]?.stringValue)
        _ = await state.record(prompt: prompt, requestID: id, sessionID: sessionID)
      default:
        break
      }
    }

    let projectRoot = try makeTemporaryDirectory(prefix: "opencode-interrupt-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "opencode-interrupt-home")
    let runtimeBase = temporaryPath(prefix: "opencode-interrupt-runtime")
    addTeardownBlock {
      for path in [projectRoot, sourceHome, runtimeBase] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )
    let handle = try await provider.start(
      try AgentExecutionRequest(
        taskID: TaskID(rawValue: "task-opencode-interrupt-steer"),
        projectID: ProjectID(rawValue: "project-opencode-interrupt-steer"),
        projectRoot: projectRoot,
        prompt: "Inspect the repository.",
        mutationIntent: .readOnly,
        workspaceStrategy: .sharedProject,
        networkAccessRequested: false,
        requiredCapabilities: [.sessionCreate, .steer]
      ),
      installation: try AgentInstallation(
        id: AgentInstallationID(rawValue: "installation-opencode-interrupt-steer"),
        providerID: .openCode,
        executablePath: "/bin/echo"
      )
    )

    for _ in 0..<100 {
      if await state.recordedPromptCount >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await XCTUnwrap(handle.control.steer)("Follow the failing test.")
    try await handle.control.interrupt()
    let firstRequestIDValue = await state.takeFirstRequestID()
    let firstRequestID = try XCTUnwrap(firstRequestIDValue)
    try await transport.emit(
      ACPWireMessage(id: firstRequestID, result: .object(["stopReason": .string("end_turn")]))
    )

    var events: [AgentEventEnvelope] = []
    for try await event in handle.events {
      events.append(event)
    }
    let prompts = await transport.sentMessages()
      .filter { $0.method == "session/prompt" }
      .compactMap(Self.promptText(from:))
    XCTAssertEqual(prompts, ["Inspect the repository."])
    XCTAssertTrue(events.contains { if case .interrupted = $0.event { true } else { false } })
    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
  }

  private static func initializationResult() -> ACPJSONValue {
    .object([
      "protocolVersion": .integer(1),
      "agentCapabilities": .object([
        "sessionCapabilities": .object(["close": .object([:])])
      ]),
      "agentInfo": .object([
        "name": .string("OpenCode"),
        "title": .string("OpenCode"),
        "version": .string("1.18.23"),
      ]),
    ])
  }

  private static func sessionResult() -> ACPJSONValue {
    .object([
      "sessionId": .string("session-steer"),
      "configOptions": sessionConfigOptions(),
    ])
  }

  private static func sessionConfigOptions() -> ACPJSONValue {
    .array([
      .object([
        "id": .string("model"),
        "currentValue": .string("opencode/x-preview-f-free"),
        "options": .array([
          .object([
            "value": .string("opencode/x-preview-f-free"),
            "name": .string("OpenCode Free"),
          ])
        ]),
      ]),
      .object([
        "id": .string("mode"),
        "currentValue": .string("plan"),
        "options": .array([
          .object(["value": .string("plan"), "name": .string("Plan")]),
          .object(["value": .string("build"), "name": .string("Build")]),
        ]),
      ]),
    ])
  }

  private static func messageUpdate(text: String, messageID: String) -> ACPJSONValue {
    .object([
      "sessionId": .string("session-steer"),
      "update": .object([
        "sessionUpdate": .string("agent_message_chunk"),
        "messageId": .string(messageID),
        "content": .object([
          "type": .string("text"),
          "text": .string(text),
        ]),
      ]),
    ])
  }

  private static func promptText(from message: ACPWireMessage) -> String? {
    message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue
  }

  private func makeTemporaryDirectory(prefix: String) throws -> String {
    let path = temporaryPath(prefix: prefix)
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  private func temporaryPath(prefix: String) -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true).path
  }
}

private actor SteerPromptState {
  private(set) var prompts: [(String, ACPRequestID, String)] = []

  var recordedPromptCount: Int { prompts.count }

  var sessionIDs: [String] { prompts.map { $0.2 } }

  func record(prompt: String, requestID: ACPRequestID, sessionID: String) -> Int {
    prompts.append((prompt, requestID, sessionID))
    return prompts.count
  }

  func takeFirstRequestID() -> ACPRequestID? {
    prompts.first?.1
  }
}
