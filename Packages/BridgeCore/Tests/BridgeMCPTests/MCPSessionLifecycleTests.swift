import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPSessionLifecycleTests: XCTestCase {
  func testInitializeCreatesSessionAndDeleteStopsIt() async throws {
    let registry = makeRegistry(port: 19_321)
    addTeardownBlock { await registry.stop() }

    let initialized = await registry.handle(initializeRequest(port: 19_321))
    XCTAssertEqual(initialized.statusCode, 200)
    let sessionID = try XCTUnwrap(initialized.headers[HTTPHeaderName.sessionID])
    let countAfterInitialize = await registry.activeSessionCount
    XCTAssertEqual(countAfterInitialize, 1)

    let deleted = await registry.handle(
      HTTPRequest(
        method: "DELETE",
        headers: [
          HTTPHeaderName.host: "127.0.0.1:19321",
          HTTPHeaderName.sessionID: sessionID,
        ]
      )
    )
    XCTAssertEqual(deleted.statusCode, 200)
    let countAfterDelete = await registry.activeSessionCount
    XCTAssertEqual(countAfterDelete, 0)
  }

  func testSessionCapacityAndUnknownSessionFailClosed() async throws {
    let registry = makeRegistry(
      port: 19_322,
      limits: .init(maximumSessions: 1)
    )
    addTeardownBlock { await registry.stop() }

    let first = await registry.handle(initializeRequest(port: 19_322))
    XCTAssertEqual(first.statusCode, 200)
    let second = await registry.handle(initializeRequest(port: 19_322))
    XCTAssertEqual(second.statusCode, 503)

    let unknown = await registry.handle(
      HTTPRequest(
        method: "GET",
        headers: [
          HTTPHeaderName.host: "127.0.0.1:19322",
          HTTPHeaderName.accept: "text/event-stream",
          HTTPHeaderName.sessionID: "unknown",
        ]
      )
    )
    XCTAssertEqual(unknown.statusCode, 404)
  }

  func testEmissionBudgetRetiresSessionOnNextRequest() async throws {
    let registry = makeRegistry(
      port: 19_323,
      limits: .init(maximumEmittedBytes: 8)
    )
    addTeardownBlock { await registry.stop() }
    let initialized = await registry.handle(initializeRequest(port: 19_323))
    let sessionID = try XCTUnwrap(initialized.headers[HTTPHeaderName.sessionID])

    await registry.recordEmittedBytes(sessionID: sessionID, byteCount: 9)
    let retired = await registry.handle(
      HTTPRequest(
        method: "GET",
        headers: [
          HTTPHeaderName.host: "127.0.0.1:19323",
          HTTPHeaderName.accept: "text/event-stream",
          HTTPHeaderName.sessionID: sessionID,
        ]
      )
    )

    XCTAssertEqual(retired.statusCode, 404)
    let activeCount = await registry.activeSessionCount
    XCTAssertEqual(activeCount, 0)
  }

  func testExactBoundPortParticipatesInOriginValidation() async {
    let registry = makeRegistry(port: 19_324)
    addTeardownBlock { await registry.stop() }
    var request = initializeRequest(port: 19_324)
    request = HTTPRequest(
      method: request.method,
      headers: request.headers.merging([
        HTTPHeaderName.host: "127.0.0.1:19325"
      ]) { _, replacement in replacement },
      body: request.body,
      path: request.path
    )

    let response = await registry.handle(request)

    XCTAssertEqual(response.statusCode, 421)
    let activeCount = await registry.activeSessionCount
    XCTAssertEqual(activeCount, 0)
  }

  func testPendingInitializationConsumesSessionCapacity() async {
    let gate = ServerFactoryGate()
    let registry = MCPSessionRegistry(
      boundPort: 19_325,
      limits: .init(maximumSessions: 1)
    ) { _ in
      await gate.suspendFactory()
      return Self.makeServer()
    }
    addTeardownBlock { await registry.stop() }

    let firstRequest = initializeRequest(port: 19_325)
    let first = Task { await registry.handle(firstRequest) }
    await gate.waitUntilFactorySuspended()
    let second = await registry.handle(initializeRequest(port: 19_325))

    XCTAssertEqual(second.statusCode, 503)
    await gate.resumeFactory()
    let firstResponse = await first.value
    XCTAssertEqual(firstResponse.statusCode, 200)
  }

  func testStopDuringInitializationCannotResurrectSession() async {
    let gate = ServerFactoryGate()
    let registry = MCPSessionRegistry(boundPort: 19_326) { _ in
      await gate.suspendFactory()
      return Self.makeServer()
    }

    let request = initializeRequest(port: 19_326)
    let initialization = Task { await registry.handle(request) }
    await gate.waitUntilFactorySuspended()
    await registry.stop()
    await gate.resumeFactory()

    let response = await initialization.value
    XCTAssertEqual(response.statusCode, 503)
    let activeCount = await registry.activeSessionCount
    XCTAssertEqual(activeCount, 0)
  }

  func testServerDiscoverAnswersOpenAIClientProbeAndInitializationStillWorks() async throws {
    let registry = MCPSessionRegistry(
      boundPort: 19_327,
      serverFactory: { _ in Self.makeServer() },
      discoveryInstructionsProvider: { _ in "全局 GPT 自定义指令" }
    )
    addTeardownBlock { await registry.stop() }

    let discoverBody = Data(
      """
      {"jsonrpc":"2.0","id":"openai-mcp-discover","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"openai-mcp","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{"experimental":{"openai/visibility":{"enabled":true}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}}}
      """.utf8
    )
    let discovered = await registry.handle(
      HTTPRequest(
        method: "POST",
        headers: [
          HTTPHeaderName.host: "127.0.0.1:19327",
          HTTPHeaderName.accept: "application/json, text/event-stream",
          HTTPHeaderName.contentType: "application/json",
          "Mcp-Protocol-Version": "2026-07-28",
          "Mcp-Method": "server/discover",
        ],
        body: discoverBody,
        path: "/mcp"
      )
    )
    XCTAssertEqual(discovered.statusCode, 200)
    let payload = try XCTUnwrap(
      discovered.bodyData,
      "discover response must carry a JSON-RPC body"
    )
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      "discover response must be valid JSON"
    )
    XCTAssertEqual(object["id"] as? String, "openai-mcp-discover")
    let result = try XCTUnwrap(object["result"] as? [String: Any])
    XCTAssertEqual(result["resultType"] as? String, "complete")
    let versions = try XCTUnwrap(result["supportedVersions"] as? [String])
    XCTAssertEqual(versions, ["2026-07-28", Version.latest])
    XCTAssertNotNil(result["capabilities"])
    XCTAssertNotNil(result["_meta"])
    XCTAssertEqual(result["instructions"] as? String, "全局 GPT 自定义指令")
    let countAfterDiscover = await registry.activeSessionCount
    XCTAssertEqual(countAfterDiscover, 0, "discovery must not create a session")

    let initialized = await registry.handle(initializeRequest(port: 19_327))
    XCTAssertEqual(initialized.statusCode, 200)
    XCTAssertNotNil(initialized.headers[HTTPHeaderName.sessionID])
  }

  func testSessionIsBoundToAuthenticatedClientAndMismatchDoesNotCloseIt() async throws {
    let registry = authenticatedRegistry(port: 19_328)
    addTeardownBlock { await registry.stop() }
    let initialized = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_328),
        clientID: .qwenStudio
      )
    )
    let sessionID = try XCTUnwrap(initialized.headers[HTTPHeaderName.sessionID])

    let mismatch = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "GET",
          headers: [
            HTTPHeaderName.host: "127.0.0.1:19328",
            HTTPHeaderName.accept: "text/event-stream",
            HTTPHeaderName.sessionID: sessionID,
          ]
        ),
        clientID: .chatGPT
      )
    )
    XCTAssertEqual(mismatch.statusCode, 403)
    let qwenCount = await registry.activeSessionCount(for: .qwenStudio)
    XCTAssertEqual(qwenCount, 1)
  }

  func testRevokedClientCannotRegisterPendingSession() async {
    let gate = ServerFactoryGate()
    let admission = MCPClientAdmissionGate(initiallyEnabled: [.qwenStudio])
    let registry = MCPSessionRegistry(
      boundPort: 19_335,
      authenticatedServerFactory: { _, _ in
        await gate.suspendFactory()
        return Self.makeServer()
      },
      clientAdmission: admission
    )
    addTeardownBlock { await registry.stop() }

    let request = initializeRequest(port: 19_335)
    let initialization = Task {
      await registry.handle(
        AuthenticatedMCPRequest(
          request: request,
          clientID: .qwenStudio
        )
      )
    }
    await gate.waitUntilFactorySuspended()
    admission.revoke(.qwenStudio)
    await gate.resumeFactory()

    let response = await initialization.value
    XCTAssertEqual(response.statusCode, 503)
    let activeQwenSessions = await registry.activeSessionCount(for: .qwenStudio)
    XCTAssertEqual(activeQwenSessions, 0)
  }

  func testQwenReclaimsOldestSessionWithoutAffectingChatGPT() async throws {
    let registry = authenticatedRegistry(
      port: 19_329,
      limits: .init(maximumSessions: 2, maximumSessionsPerClient: 1)
    )
    addTeardownBlock { await registry.stop() }

    let firstQwen = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_329),
        clientID: .qwenStudio
      )
    )
    let firstQwenSessionID = try XCTUnwrap(firstQwen.headers[HTTPHeaderName.sessionID])
    let secondQwen = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_329),
        clientID: .qwenStudio
      )
    )
    let chatGPT = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_329),
        clientID: .chatGPT
      )
    )
    XCTAssertEqual(firstQwen.statusCode, 200)
    XCTAssertEqual(secondQwen.statusCode, 200)
    XCTAssertEqual(chatGPT.statusCode, 200)
    let retired = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "GET",
          headers: [
            HTTPHeaderName.host: "127.0.0.1:19329",
            HTTPHeaderName.accept: "text/event-stream",
            HTTPHeaderName.sessionID: firstQwenSessionID,
          ]
        ),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(retired.statusCode, 404)
    let qwenCount = await registry.activeSessionCount(for: .qwenStudio)
    let chatGPTCount = await registry.activeSessionCount(for: .chatGPT)
    XCTAssertEqual(qwenCount, 1)
    XCTAssertEqual(chatGPTCount, 1)
  }

  func testChatGPTSessionLimitStillFailsClosed() async {
    let registry = authenticatedRegistry(
      port: 19_333,
      limits: .init(maximumSessions: 2, maximumSessionsPerClient: 1)
    )
    addTeardownBlock { await registry.stop() }

    let first = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_333),
        clientID: .chatGPT
      )
    )
    let second = await registry.handle(
      AuthenticatedMCPRequest(
        request: initializeRequest(port: 19_333),
        clientID: .chatGPT
      )
    )

    XCTAssertEqual(first.statusCode, 200)
    XCTAssertEqual(second.statusCode, 503)
    let chatGPTCount = await registry.activeSessionCount(for: .chatGPT)
    XCTAssertEqual(chatGPTCount, 1)
  }

  func testQwenSessionLeakCannotExhaustItsClientCapacity() async {
    let registry = authenticatedRegistry(
      port: 19_334,
      limits: .init(maximumSessions: 3, maximumSessionsPerClient: 2)
    )
    addTeardownBlock { await registry.stop() }

    for _ in 0..<20 {
      let response = await registry.handle(
        AuthenticatedMCPRequest(
          request: initializeRequest(port: 19_334),
          clientID: .qwenStudio
        )
      )
      XCTAssertEqual(response.statusCode, 200)
    }

    let qwenCount = await registry.activeSessionCount(for: .qwenStudio)
    XCTAssertEqual(qwenCount, 2)
  }

  func testModernDiscoveryIsAvailableToQwenWithItsOwnAuthenticatedContext() async throws {
    let registry = authenticatedRegistry(port: 19_330)
    addTeardownBlock { await registry.stop() }
    let body = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
      """.utf8
    )
    let response = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "POST",
          headers: [
            HTTPHeaderName.host: "127.0.0.1:19330",
            HTTPHeaderName.accept: "application/json, text/event-stream",
            HTTPHeaderName.contentType: "application/json",
            "Mcp-Protocol-Version": "2026-07-28",
            "Mcp-Method": "server/discover",
          ],
          body: body,
          path: "/mcp"
        ),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(response.statusCode, 200)
    let data = try XCTUnwrap(response.bodyData)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(object["id"] as? Int, 1)
    let qwenCount = await registry.activeSessionCount(for: .qwenStudio)
    XCTAssertEqual(qwenCount, 0)
  }

  func testModernRoutingHeadersMustMatchRequestBody() async {
    let registry = authenticatedRegistry(port: 19_332)
    addTeardownBlock { await registry.stop() }
    let body = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
      """.utf8
    )
    let response = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "POST",
          headers: [
            HTTPHeaderName.host: "127.0.0.1:19332",
            HTTPHeaderName.accept: "application/json",
            HTTPHeaderName.contentType: "application/json",
            "Mcp-Protocol-Version": "2026-07-28",
            "Mcp-Method": "tools/call",
          ],
          body: body,
          path: "/mcp"
        ),
        clientID: .qwenStudio
      )
    )

    XCTAssertEqual(response.statusCode, 400)
  }

  func testModernRequestsRequireCompleteRoutingEnvelope() async throws {
    let registry = authenticatedRegistry(port: 19_335)
    addTeardownBlock { await registry.stop() }
    let completeBody = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bridge_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
      """.utf8
    )
    let headers = [
      HTTPHeaderName.host: "127.0.0.1:19335",
      HTTPHeaderName.accept: "application/json",
      HTTPHeaderName.contentType: "application/json",
      "Mcp-Protocol-Version": "2026-07-28",
    ]

    let missingMethod = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(method: "POST", headers: headers, body: completeBody, path: "/mcp"),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(missingMethod.statusCode, 400)
    XCTAssertEqual(try modernErrorCode(missingMethod), -32_020)

    let missingName = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "POST",
          headers: headers.merging(["Mcp-Method": "tools/call"]) { _, value in value },
          body: completeBody,
          path: "/mcp"
        ),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(missingName.statusCode, 400)
    XCTAssertEqual(try modernErrorCode(missingName), -32_020)

    let missingMetadata = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "POST",
          headers: headers.merging([
            "Mcp-Method": "tools/list"
          ]) { _, value in value },
          body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8),
          path: "/mcp"
        ),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(missingMetadata.statusCode, 400)
    XCTAssertEqual(try modernErrorCode(missingMetadata), -32_600)
  }

  func testModernProtocolVersionMustMatchRequestMetadata() async throws {
    let registry = authenticatedRegistry(port: 19_336)
    addTeardownBlock { await registry.stop() }
    let body = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18","io.modelcontextprotocol/clientCapabilities":{}}}}
      """.utf8
    )
    let response = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: "POST",
          headers: [
            HTTPHeaderName.host: "127.0.0.1:19336",
            HTTPHeaderName.accept: "application/json",
            HTTPHeaderName.contentType: "application/json",
            "Mcp-Protocol-Version": "2026-07-28",
            "Mcp-Method": "tools/list",
          ],
          body: body,
          path: "/mcp"
        ),
        clientID: .qwenStudio
      )
    )

    XCTAssertEqual(response.statusCode, 400)
    XCTAssertEqual(try modernErrorCode(response), -32_020)
  }

  func testModernToolsListReturnsRequestScopedServerMetadata() async throws {
    let registry = MCPSessionRegistry(
      boundPort: 19_337,
      authenticatedServerFactory: { _, _ in Self.makeServer() },
      authenticatedStatelessServerFactory: { _ in
        let server = Server(
          name: "codex-bridge-modern-test",
          version: "0.1.0",
          capabilities: .init(tools: .init()),
          configuration: .default
        )
        await server.withMethodHandler(ListTools.self) { _ in
          ListTools.Result(tools: [])
        }
        return server
      }
    )
    addTeardownBlock { await registry.stop() }
    let body = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
      """.utf8
    )
    let request = HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.host: "127.0.0.1:19337",
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
        "Mcp-Protocol-Version": "2026-07-28",
        "Mcp-Method": "tools/list",
      ],
      body: body,
      path: "/mcp"
    )
    let response = await registry.handle(
      AuthenticatedMCPRequest(
        request: request,
        clientID: .qwenStudio
      )
    )

    XCTAssertEqual(response.statusCode, 200)
    let data = try XCTUnwrap(response.bodyData)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let result = try XCTUnwrap(object["result"] as? [String: Any])
    let metadata = try XCTUnwrap(result["_meta"] as? [String: Any])
    XCTAssertNotNil(metadata["io.modelcontextprotocol/serverInfo"])

    let jsonOnly = await registry.handle(
      AuthenticatedMCPRequest(
        request: HTTPRequest(
          method: request.method,
          headers: request.headers.merging([
            HTTPHeaderName.accept: "application/json"
          ]) { _, replacement in replacement },
          body: request.body,
          path: request.path
        ),
        clientID: .qwenStudio
      )
    )
    XCTAssertEqual(jsonOnly.statusCode, 406)
  }

  func testTerminatingClientStopsActiveModernServer() async throws {
    let handlerStarted = expectation(description: "modern tool handler started")
    let admission = MCPClientAdmissionGate(initiallyEnabled: [.qwenStudio])
    let registry = MCPSessionRegistry(
      boundPort: 19_339,
      authenticatedServerFactory: { _, _ in Self.makeServer() },
      authenticatedStatelessServerFactory: { _ in
        let server = Server(
          name: "codex-bridge-modern-termination-test",
          version: "0.1.0",
          capabilities: .init(tools: .init()),
          configuration: .default
        )
        await server.withMethodHandler(CallTool.self) { _ in
          handlerStarted.fulfill()
          try? await Task.sleep(for: .seconds(2))
          return CallTool.Result(content: [.text(text: "late", annotations: nil, _meta: nil)])
        }
        return server
      },
      clientAdmission: admission
    )
    addTeardownBlock { await registry.stop() }
    let request = HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.host: "127.0.0.1:19339",
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
        "Mcp-Protocol-Version": "2026-07-28",
        "Mcp-Method": "tools/call",
        "Mcp-Name": "slow_tool",
      ],
      body: Data(
        """
        {"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"slow_tool","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8
      ),
      path: "/mcp"
    )
    let call = Task {
      await registry.handle(
        AuthenticatedMCPRequest(request: request, clientID: .qwenStudio)
      )
    }

    await fulfillment(of: [handlerStarted], timeout: 1)
    admission.revoke(.qwenStudio)
    await registry.terminateSessions(for: .qwenStudio)
    let response = await call.value
    XCTAssertEqual(response.statusCode, 500)
    let activeModernRequests = await registry.activeStatelessServerCount
    XCTAssertEqual(activeModernRequests, 0)
    let activeQwenSessions = await registry.activeSessionCount(for: .qwenStudio)
    XCTAssertEqual(activeQwenSessions, 0)
  }

  func testCancellingModernRequestDisconnectsItsTransport() async throws {
    let handlerStarted = expectation(description: "modern tool handler started")
    let registry = MCPSessionRegistry(
      boundPort: 19_338,
      authenticatedServerFactory: { _, _ in Self.makeServer() },
      authenticatedStatelessServerFactory: { _ in
        let server = Server(
          name: "codex-bridge-modern-cancellation-test",
          version: "0.1.0",
          capabilities: .init(tools: .init()),
          configuration: .default
        )
        await server.withMethodHandler(CallTool.self) { _ in
          handlerStarted.fulfill()
          try? await Task.sleep(for: .seconds(2))
          return CallTool.Result(content: [.text(text: "late", annotations: nil, _meta: nil)])
        }
        return server
      }
    )
    addTeardownBlock { await registry.stop() }
    let request = HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.host: "127.0.0.1:19338",
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
        "Mcp-Protocol-Version": "2026-07-28",
        "Mcp-Method": "tools/call",
        "Mcp-Name": "slow_tool",
      ],
      body: Data(
        """
        {"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"slow_tool","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8
      ),
      path: "/mcp"
    )
    let call = Task {
      await registry.handle(
        AuthenticatedMCPRequest(request: request, clientID: .qwenStudio)
      )
    }

    await fulfillment(of: [handlerStarted], timeout: 1)
    call.cancel()
    let response = await call.value
    XCTAssertEqual(response.statusCode, 500)
    let activeModernRequests = await registry.activeStatelessServerCount
    XCTAssertEqual(activeModernRequests, 0)
  }

  func testRemoteOpenAIOriginIsAllowedOnlyForChatGPTCredential() async {
    let registry = authenticatedRegistry(port: 19_331)
    addTeardownBlock { await registry.stop() }
    let base = initializeRequest(port: 19_331)
    let request = HTTPRequest(
      method: base.method,
      headers: base.headers.merging([
        HTTPHeaderName.origin: "https://chatgpt.com"
      ]) { _, replacement in replacement },
      body: base.body,
      path: base.path
    )

    let qwen = await registry.handle(
      AuthenticatedMCPRequest(request: request, clientID: .qwenStudio)
    )
    let chatGPT = await registry.handle(
      AuthenticatedMCPRequest(request: request, clientID: .chatGPT)
    )

    XCTAssertEqual(qwen.statusCode, 403)
    XCTAssertEqual(chatGPT.statusCode, 200)
  }

  private func makeRegistry(
    port: Int,
    limits: MCPSessionRegistry.Limits = .init()
  ) -> MCPSessionRegistry {
    MCPSessionRegistry(boundPort: port, limits: limits) { _ in
      Self.makeServer()
    }
  }

  private func authenticatedRegistry(
    port: Int,
    limits: MCPSessionRegistry.Limits = .init()
  ) -> MCPSessionRegistry {
    MCPSessionRegistry(
      boundPort: port,
      limits: limits,
      authenticatedServerFactory: { _, _ in Self.makeServer() }
    )
  }

  private static func makeServer() -> Server {
    Server(
      name: "codex-bridge-test",
      version: "0.1.0",
      capabilities: .init(),
      configuration: .strict
    )
  }

  private func initializeRequest(port: Int) -> HTTPRequest {
    let body = Data(
      """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-test","version":"1"}}}
      """.utf8
    )
    return HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.host: "127.0.0.1:\(port)",
        HTTPHeaderName.accept: "application/json, text/event-stream",
        HTTPHeaderName.contentType: "application/json",
      ],
      body: body,
      path: "/mcp/test"
    )
  }

  private func modernErrorCode(_ response: HTTPResponse) throws -> Int {
    let data = try XCTUnwrap(response.bodyData)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let error = try XCTUnwrap(object["error"] as? [String: Any])
    return try XCTUnwrap(error["code"] as? Int)
  }
}

private actor ServerFactoryGate {
  private var isSuspended = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var factoryWaiter: CheckedContinuation<Void, Never>?

  func suspendFactory() async {
    isSuspended = true
    for waiter in entryWaiters {
      waiter.resume()
    }
    entryWaiters.removeAll(keepingCapacity: false)
    await withCheckedContinuation { factoryWaiter = $0 }
  }

  func waitUntilFactorySuspended() async {
    guard !isSuspended else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func resumeFactory() {
    factoryWaiter?.resume()
    factoryWaiter = nil
  }
}
