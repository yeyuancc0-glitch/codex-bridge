import BridgeACP
import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPClientTests: XCTestCase {
  func testInitializeAcceptsProtocolResponseWithoutOptionalAgentInfo() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(["protocolVersion": .integer(1)]))
      )
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }

    let initialization = try await client.initialize()

    XCTAssertEqual(initialization.protocolVersion, 1)
    XCTAssertNil(initialization.agentName)
    XCTAssertNil(initialization.agentVersion)
  }

  func testInitializeFreshSessionAndPromptPreserveTextOrderAndBarrier() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(
            id: id,
            sessionID: "session-1",
            configOptions: deepSeekModelConfigOptions()
          )
        )
      case "session/set_config_option":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object([
              "configOptions": .array(
                deepSeekModelConfigOptions(currentModel: "gateway-new", currentEffort: "off")
              )
            ])
          )
        )
      case "session/prompt":
        try await transport.emit(deepSeekMessageChunk(sessionID: "session-1", text: "Hello "))
        try await transport.emit(deepSeekMessageChunk(sessionID: "session-1", text: "world"))
        try await transport.emit(deepSeekPermissionRequest(sessionID: "session-1"))
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
    addTeardownBlock { await client.shutdown() }

    let initialization = try await client.initialize()
    XCTAssertEqual(initialization.protocolVersion, 1)
    XCTAssertEqual(initialization.agentName, DeepSeekHarnessACPConstants.agentName)
    let session = try await client.newSession(cwd: "/tmp")
    XCTAssertEqual(session.id, "session-1")
    XCTAssertEqual(session.configOptions.first?.category, "model")
    XCTAssertEqual(
      session.configOptions.first?.values.map(\.value),
      [
        "deepseek-v4-pro", "gateway-new",
      ])
    let changed = try await client.setSessionConfigOption(
      sessionID: session.id,
      configID: "model",
      value: "gateway-new"
    )
    XCTAssertEqual(changed.first?.currentValue, "gateway-new")
    XCTAssertEqual(changed.last?.currentValue, "off")

    let prompt = Task {
      try await client.prompt(sessionID: session.id, text: "Say hello")
    }
    var events: [DeepSeekHarnessACPClientEventEnvelope] = []
    var iterator = client.events.makeAsyncIterator()
    while events.count < 3, let event = await iterator.next() {
      events.append(event)
    }
    let result = try await prompt.value
    XCTAssertEqual(result.stopReason, "end_turn")
    XCTAssertEqual(result.eventSequenceBarrier, 3)
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2])
    XCTAssertEqual(
      events.compactMap { event -> String? in
        guard case .textDelta(_, let text) = event.event else { return nil }
        return text
      },
      ["Hello ", "world"]
    )

    let sent = await transport.sentMessages()
    let newSession = try XCTUnwrap(sent.first { $0.method == "session/new" })
    XCTAssertEqual(newSession.params?["mcpServers"], .array([]))
    XCTAssertEqual(newSession.params?["additionalDirectories"], .array([]))
    let permissionReply = try XCTUnwrap(
      sent.first { $0.id == .string("permission-1") && $0.method == nil }
    )
    XCTAssertEqual(
      permissionReply.result?["outcome"]?["outcome"],
      .string("selected")
    )
    XCTAssertEqual(permissionReply.result?["outcome"]?["optionId"], .string("reject-once"))
  }

  func testPermissionWithoutNestedToolCallOrRejectKindFailsClosed() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "session-2"))
      case "session/prompt":
        try await transport.emit(
          ACPWireMessage(
            id: .string("permission-bad"),
            method: "session/request_permission",
            params: .object([
              "sessionId": .string("session-2"),
              "toolCallId": .string("tool-2"),
              "options": .array([
                .object([
                  "optionId": .string("reject_once"),
                  "kind": .string("allow_once"),
                ])
              ]),
            ])
          )
        )
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
    let prompt = Task { try await client.prompt(sessionID: session.id, text: "permission") }
    do {
      _ = try await prompt.value
      XCTFail("Expected malformed permission to terminate the client")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .malformedPermission)
    }
  }

  func testWrongSessionUpdateTerminatesClient() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "session-3"))
      case "session/prompt":
        try await transport.emit(deepSeekMessageChunk(sessionID: "wrong", text: "bad"))
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
    do {
      _ = try await client.prompt(sessionID: session.id, text: "wrong session")
      XCTFail("Expected a mismatched session to fail")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .sessionMismatch)
    }
  }

  func testUnknownResponseIDFailsClosed() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", message.id != nil else { return }
      try await transport.emit(
        ACPWireMessage(id: .string("unknown"), result: .object(["protocolVersion": .integer(1)]))
      )
    }
    let client = DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    addTeardownBlock { await client.shutdown() }
    do {
      _ = try await client.initialize()
      XCTFail("Expected an unknown response id to fail closed")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .transportClosed)
    }
  }

  func testDuplicateResponseAfterSettlementFailsClosed() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "duplicate-session"))
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "duplicate-session"))
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
    _ = try await client.newSession(cwd: "/tmp")
    try await Task.sleep(for: .milliseconds(50))
    do {
      _ = try await client.prompt(sessionID: "duplicate-session", text: "closed")
      XCTFail("Expected duplicate response to close the client")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .transportClosed)
    }
  }
}
