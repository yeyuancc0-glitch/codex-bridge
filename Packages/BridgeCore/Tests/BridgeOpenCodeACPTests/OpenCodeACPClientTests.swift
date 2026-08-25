import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPClientTests: XCTestCase {
  func testNegotiatesSessionStreamsEventsAndRejectsPermission() async throws {
    let transport = ScriptedACPTransport()
    let state = ACPPromptScenarioState()
    await transport.setHandler { message, transport in
      if message.method == "initialize", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object([
              "protocolVersion": .integer(1),
              "agentCapabilities": .object([
                "loadSession": .bool(true),
                "sessionCapabilities": .object([
                  "resume": .object([:]),
                  "close": .object([:]),
                ]),
              ]),
              "agentInfo": .object([
                "name": .string("opencode"),
                "title": .string("OpenCode"),
                "version": .string("1.2.3"),
              ]),
            ])
          )
        )
        return
      }
      if message.method == "session/new", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["sessionId": .string("session-1")])
          )
        )
        return
      }
      if message.method == "session/prompt", let id = message.id {
        await state.setPromptRequestID(id)
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.messageUpdate(text: "Hello ", messageID: "message-1")
          )
        )
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.toolUpdate(status: "pending")
          )
        )
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.messageUpdate(text: "world", messageID: "message-1")
          )
        )
        try await transport.emit(Self.permissionRequest())
        return
      }
      if message.id == .string("permission-1"), message.method == nil {
        await state.setPermissionReply(message)
        guard let promptID = await state.takePromptRequestID() else {
          throw OpenCodeACPError.invalidMessage
        }
        try await transport.emit(
          ACPWireMessage(
            id: promptID,
            result: .object(["stopReason": .string("end_turn")])
          )
        )
      }
    }

    let client = OpenCodeACPClient(
      transport: transport,
      clientInfo: OpenCodeACPClientInfo(
        name: "codex-bridge-tests",
        title: "Codex Bridge Tests",
        version: "1.0"
      )
    )
    addTeardownBlock { await client.shutdown() }

    let initialization = try await client.initialize()
    XCTAssertEqual(initialization.protocolVersion, 1)
    XCTAssertEqual(initialization.agentVersion, "1.2.3")
    XCTAssertTrue(initialization.supportsLoadSession)
    XCTAssertTrue(initialization.supportsResumeSession)
    XCTAssertTrue(initialization.supportsCloseSession)

    let session = try await client.newSession(cwd: FileManager.default.temporaryDirectory.path)
    XCTAssertEqual(session.id, "session-1")

    var events = client.events.makeAsyncIterator()
    let prompt = Task {
      try await client.prompt(sessionID: session.id, text: "Say hello")
    }

    guard let firstEnvelope = await events.next(),
      let secondEnvelope = await events.next(),
      let thirdEnvelope = await events.next(),
      let permissionEnvelope = await events.next(),
      case .notification(let first) = firstEnvelope.event,
      case .notification(let second) = secondEnvelope.event,
      case .notification(let third) = thirdEnvelope.event,
      case .permissionDenied(let denied) = permissionEnvelope.event
    else {
      return XCTFail("Expected three updates followed by a denied permission request")
    }
    XCTAssertEqual(
      [
        firstEnvelope.sequence, secondEnvelope.sequence, thirdEnvelope.sequence,
        permissionEnvelope.sequence,
      ],
      [0, 1, 2, 3]
    )
    XCTAssertEqual(first.method, "session/update")
    XCTAssertEqual(second.method, "session/update")
    XCTAssertEqual(third.method, "session/update")
    XCTAssertEqual(denied.sessionID, session.id)
    XCTAssertEqual(denied.toolCallID, "tool-1")

    let result = try await prompt.value
    XCTAssertEqual(result.stopReason, "end_turn")
    XCTAssertEqual(result.eventSequenceBarrier, 4)

    let reply = await state.permissionReplyValue()
    XCTAssertEqual(reply?.result?["outcome"]?["outcome"], .string("selected"))
    XCTAssertEqual(reply?.result?["outcome"]?["optionId"], .string("reject"))
  }

  func testRejectsResponseContainingResultAndError() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(
        ACPWireMessage(
          id: id,
          result: .object(["protocolVersion": .integer(1)]),
          error: ACPWireError(code: -1, message: "invalid")
        )
      )
    }
    let client = OpenCodeACPClient(
      transport: transport,
      clientInfo: OpenCodeACPClientInfo(name: "test", title: "Test", version: "1")
    )
    addTeardownBlock { await client.shutdown() }

    do {
      _ = try await client.initialize()
      XCTFail("Expected invalid JSON-RPC response shape")
    } catch {
      XCTAssertEqual(error as? OpenCodeACPError, .invalidMessage)
    }
  }

  func testInitializeIsSingleFlightAcrossConcurrentCallers() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await Task.sleep(for: .milliseconds(50))
      try await transport.emit(Self.initializationResponse(id: id))
    }
    let client = OpenCodeACPClient(
      transport: transport,
      clientInfo: OpenCodeACPClientInfo(name: "test", title: "Test", version: "1")
    )
    addTeardownBlock { await client.shutdown() }

    async let first = client.initialize()
    async let second = client.initialize()
    let values = try await [first, second]

    XCTAssertEqual(values.map(\.protocolVersion), [1, 1])
    let initializeRequests = await transport.sentMessages().filter {
      $0.method == "initialize"
    }
    XCTAssertEqual(initializeRequests.count, 1)
  }

  func testConcurrentSessionCreationFailsClosed() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      if message.method == "initialize", let id = message.id {
        try await transport.emit(Self.initializationResponse(id: id))
        return
      }
      guard message.method == "session/new", let id = message.id else { return }
      try await Task.sleep(for: .milliseconds(100))
      try await transport.emit(
        ACPWireMessage(
          id: id,
          result: .object(["sessionId": .string("session-concurrent")])
        )
      )
    }
    let client = OpenCodeACPClient(
      transport: transport,
      clientInfo: OpenCodeACPClientInfo(name: "test", title: "Test", version: "1")
    )
    addTeardownBlock { await client.shutdown() }
    _ = try await client.initialize()

    let first = Task {
      try await client.newSession(cwd: FileManager.default.temporaryDirectory.path)
    }
    try await waitForSentMethod("session/new", transport: transport)

    do {
      _ = try await client.newSession(cwd: FileManager.default.temporaryDirectory.path)
      XCTFail("Expected concurrent session creation to be rejected")
    } catch {
      XCTAssertEqual(error as? OpenCodeACPError, .operationInProgress)
    }
    let created = try await first.value
    XCTAssertEqual(created.id, "session-concurrent")
  }

  func testCancelCanPassWhilePromptRequestIsInFlight() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      if message.method == "initialize", let id = message.id {
        try await transport.emit(Self.initializationResponse(id: id))
        return
      }
      if message.method == "session/new", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["sessionId": .string("session-cancel")])
          )
        )
        return
      }
      guard message.method == "session/prompt", let id = message.id else { return }
      try await Task.sleep(for: .milliseconds(100))
      try await transport.emit(
        ACPWireMessage(
          id: id,
          result: .object(["stopReason": .string("cancelled")])
        )
      )
    }
    let client = OpenCodeACPClient(
      transport: transport,
      clientInfo: OpenCodeACPClientInfo(name: "test", title: "Test", version: "1")
    )
    addTeardownBlock { await client.shutdown() }
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: FileManager.default.temporaryDirectory.path)

    let prompt = Task {
      try await client.prompt(sessionID: session.id, text: "Keep working")
    }
    try await waitForSentMethod("session/prompt", transport: transport)
    try await client.cancel(sessionID: session.id)

    let sent = await transport.sentMessages()
    XCTAssertTrue(sent.contains { $0.method == "session/cancel" })
    let result = try await prompt.value
    XCTAssertEqual(result.stopReason, "cancelled")
  }

  private static func initializationResponse(id: ACPRequestID) -> ACPWireMessage {
    ACPWireMessage(
      id: id,
      result: .object([
        "protocolVersion": .integer(1),
        "agentCapabilities": .object([:]),
      ])
    )
  }

  private func waitForSentMethod(
    _ method: String,
    transport: ScriptedACPTransport
  ) async throws {
    for _ in 0..<200 {
      if await transport.sentMessages().contains(where: { $0.method == method }) {
        return
      }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for \(method)")
  }

  private static func messageUpdate(text: String, messageID: String) -> ACPJSONValue {
    .object([
      "sessionId": .string("session-1"),
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

  private static func toolUpdate(status: String) -> ACPJSONValue {
    .object([
      "sessionId": .string("session-1"),
      "update": .object([
        "sessionUpdate": .string("tool_call"),
        "toolCallId": .string("tool-1"),
        "title": .string("Read file"),
        "kind": .string("read"),
        "status": .string(status),
      ]),
    ])
  }

  private static func permissionRequest() -> ACPWireMessage {
    ACPWireMessage(
      id: .string("permission-1"),
      method: "session/request_permission",
      params: .object([
        "sessionId": .string("session-1"),
        "toolCall": .object([
          "toolCallId": .string("tool-1"),
          "title": .string("Run command"),
          "kind": .string("execute"),
          "rawInput": .object(["command": .string("git status")]),
        ]),
        "options": .array([
          .object([
            "optionId": .string("once"),
            "name": .string("Allow once"),
            "kind": .string("allow_once"),
          ]),
          .object([
            "optionId": .string("reject"),
            "name": .string("Reject"),
            "kind": .string("reject_once"),
          ]),
        ]),
      ])
    )
  }
}
