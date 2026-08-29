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
        try await transport.emit(
          deepSeekToolUpdate(
            sessionID: "session-1",
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
            sessionID: "session-1",
            updateType: "tool_call_update",
            toolCallID: "read-1",
            status: "completed"
          )
        )
        try await transport.emit(deepSeekMessageChunk(sessionID: "session-1", text: "world"))
        try await transport.emit(deepSeekPermissionRequest(sessionID: "session-1"))
        try await transport.emit(deepSeekPromptResult(id: id, outcome: "completed", toolCalls: 1))
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
    while events.count < 5, let event = await iterator.next() {
      events.append(event)
    }
    let result = try await prompt.value
    XCTAssertEqual(result.stopReason, "end_turn")
    XCTAssertEqual(result.eventSequenceBarrier, 5)
    XCTAssertEqual(result.executionEvidence?.turnOutcome, .completed)
    XCTAssertEqual(result.executionEvidence?.toolCalls, 1)
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3, 4])
    XCTAssertEqual(
      events.compactMap { event -> String? in
        guard case .textDelta(_, let text) = event.event else { return nil }
        return text
      },
      ["Hello ", "world"]
    )
    let toolUpdates = events.compactMap { event -> DeepSeekHarnessACPToolUpdate? in
      guard case .toolUpdated(let update) = event.event else { return nil }
      return update
    }
    XCTAssertEqual(toolUpdates.map(\.status), [.inProgress, .completed])
    XCTAssertEqual(toolUpdates.first?.rawInput?["file_path"]?.stringValue, "AGENTS.md")
    let permission = try XCTUnwrap(
      events.compactMap { event -> DeepSeekHarnessACPPermissionRequest? in
        guard case .permissionRequested(let request) = event.event else { return nil }
        return request
      }.first
    )
    XCTAssertEqual(permission.toolCallID, "tool-1")
    XCTAssertEqual(permission.options.map(\.id), ["allow-once", "reject-once"])
    try await client.resolvePermission(
      approvalID: permission.approvalID,
      optionID: "reject-once"
    )

    let sent = await transport.sentMessages()
    let newSession = try XCTUnwrap(sent.first { $0.method == "session/new" })
    XCTAssertEqual(newSession.params?["mcpServers"], .array([]))
    XCTAssertEqual(newSession.params?["additionalDirectories"], .array([]))
    let permissionReply = try XCTUnwrap(sent.first { $0.id == .string("permission-1") })
    XCTAssertEqual(
      permissionReply.result?["outcome"]?["outcome"],
      .string("selected")
    )
    XCTAssertEqual(permissionReply.result?["outcome"]?["optionId"], .string("reject-once"))
  }

  func testEmptyToolTitleIsNormalizedToNil() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "empty-title-session"))
      case "session/prompt":
        try await transport.emit(
          deepSeekToolUpdate(
            sessionID: "empty-title-session",
            updateType: "tool_call",
            toolCallID: "empty-title-tool",
            status: "in_progress",
            title: "",
            kind: "read"
          )
        )
        try await transport.emit(deepSeekPromptResult(id: id))
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
    let prompt = Task { try await client.prompt(sessionID: session.id, text: "read") }
    var iterator = client.events.makeAsyncIterator()
    guard let event = await iterator.next(),
      case .toolUpdated(let update) = event.event
    else {
      return XCTFail("Expected a tool update")
    }
    XCTAssertNil(update.title)
    XCTAssertEqual(update.kind, "read")
    _ = try await prompt.value
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

  func testPermissionInputAndPendingQueueAreBounded() async throws {
    let oversizedTransport = ScriptedDeepSeekHarnessTransport()
    await oversizedTransport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "oversized-approval"))
      case "session/prompt":
        try await transport.emit(
          deepSeekPermissionRequest(
            sessionID: "oversized-approval",
            rawInput: .object([
              "command": .string(
                String(
                  repeating: "x",
                  count: DeepSeekHarnessACPConstants.maximumPermissionInputBytes + 1
                )
              )
            ])
          )
        )
      default:
        break
      }
    }
    let oversizedClient = DeepSeekHarnessACPClient(
      transport: oversizedTransport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await oversizedClient.initialize()
    let oversizedSession = try await oversizedClient.newSession(cwd: "/tmp")
    do {
      _ = try await oversizedClient.prompt(sessionID: oversizedSession.id, text: "oversized")
      XCTFail("Expected oversized permission input to fail closed")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .malformedPermission)
    }
    await oversizedClient.shutdown()

    let capacityTransport = ScriptedDeepSeekHarnessTransport()
    await capacityTransport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "approval-capacity"))
      case "session/prompt":
        for index in 0...DeepSeekHarnessACPConstants.maximumPendingPermissions {
          try await transport.emit(
            deepSeekPermissionRequest(
              sessionID: "approval-capacity",
              requestID: .string("permission-\(index)"),
              toolCallID: "tool-\(index)"
            )
          )
        }
      default:
        break
      }
    }
    let capacityClient = DeepSeekHarnessACPClient(
      transport: capacityTransport,
      clientInfo: .init(name: "tests", title: "Tests", version: "1")
    )
    _ = try await capacityClient.initialize()
    let capacitySession = try await capacityClient.newSession(cwd: "/tmp")
    do {
      _ = try await capacityClient.prompt(sessionID: capacitySession.id, text: "capacity")
      XCTFail("Expected pending permission capacity to fail closed")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .approvalUnavailable("capacity"))
    }
    await capacityClient.shutdown()
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

  func testPermissionResolutionRejectsUnknownAndExpiredRequests() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "approval-session"))
      case "session/prompt":
        try await transport.emit(deepSeekPermissionRequest(sessionID: "approval-session"))
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
    _ = try await client.initialize()
    let session = try await client.newSession(cwd: "/tmp")
    let prompt = Task { try await client.prompt(sessionID: session.id, text: "approval") }
    var iterator = client.events.makeAsyncIterator()
    guard let event = await iterator.next(),
      case .permissionRequested(let permission) = event.event
    else {
      return XCTFail("Expected a permission request")
    }

    do {
      try await client.resolvePermission(
        approvalID: permission.approvalID,
        optionID: "unknown-option"
      )
      XCTFail("Expected an unknown option to be rejected")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .approvalUnavailable("unknown-option"))
    }
    try await client.resolvePermission(
      approvalID: permission.approvalID,
      optionID: "allow-once"
    )
    _ = try await prompt.value
    do {
      try await client.resolvePermission(
        approvalID: permission.approvalID,
        optionID: "reject-once"
      )
      XCTFail("Expected an expired request to be rejected")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .approvalUnavailable(permission.approvalID))
    }
  }

  func testShutdownAutomaticallyRejectsPendingPermission() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(deepSeekSessionResult(id: id, sessionID: "shutdown-session"))
      case "session/prompt":
        try await transport.emit(deepSeekPermissionRequest(sessionID: "shutdown-session"))
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
    let prompt = Task { try await client.prompt(sessionID: session.id, text: "shutdown") }
    var iterator = client.events.makeAsyncIterator()
    guard let event = await iterator.next(),
      case .permissionRequested = event.event
    else {
      return XCTFail("Expected a permission request")
    }

    await client.shutdown()
    do {
      _ = try await prompt.value
      XCTFail("Expected the pending prompt to close with the client")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .transportClosed)
    }
    let sent = await transport.sentMessages()
    let rejection = try XCTUnwrap(
      sent.first { $0.id == .string("permission-1") && $0.method == nil }
    )
    XCTAssertEqual(rejection.result?["outcome"]?["optionId"], .string("reject-once"))
  }
}
