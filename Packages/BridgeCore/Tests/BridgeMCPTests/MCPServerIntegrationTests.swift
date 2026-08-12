import Darwin
import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPServerIntegrationTests: XCTestCase {
  func testStrictSDKClientInitializesListsAndCallsReadOnlyTools() async throws {
    let transport = await InMemoryTransport.createConnectedPair()
    let factory = MCPServerFactory(appVersion: "0.1.0", queries: IntegrationQueries())
    let server = await factory.makeServer()
    let client = Client(
      name: "codex-bridge-integration-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }

    try await server.start(transport: transport.server)
    let initialized = try await client.connect(transport: transport.client)

    XCTAssertEqual(initialized.serverInfo.name, "codex-bridge")
    XCTAssertEqual(initialized.serverInfo.version, "0.1.0")
    XCTAssertNotNil(initialized.capabilities.tools)
    XCTAssertNil(initialized.capabilities.resources)
    XCTAssertNil(initialized.capabilities.prompts)

    let listed = try await client.listTools()
    XCTAssertEqual(listed.tools.map(\.name), MCPToolName.allCases.map(\.rawValue))
    XCTAssertNil(listed.nextCursor)

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPToolName.bridgeStatus.rawValue,
      arguments: [:]
    )
    let result = try await context.value
    XCTAssertEqual(result.isError, false)
    let structured = try XCTUnwrap(result.structuredContent)
    guard case .text(let text, _, _)? = result.content.first else {
      return XCTFail("Expected the canonical JSON text result.")
    }
    let textValue = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    XCTAssertEqual(textValue, structured)
    XCTAssertEqual(structured.objectValue?["mcp_state"], "ready")
  }

  func testPinnedSDKClientCompletesRealLoopbackHTTPRoundTrip() async throws {
    let secret = String(repeating: "A", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: IntegrationQueries(),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret)
    )
    let endpoint = try await server.start()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "codex-bridge-loopback-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }

    let initialized = try await client.connect(transport: transport)
    XCTAssertEqual(initialized.serverInfo.name, "codex-bridge")
    let listed = try await client.listTools()
    XCTAssertEqual(listed.tools.map(\.name), MCPToolName.allCases.map(\.rawValue))

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPToolName.bridgeStatus.rawValue
    )
    let result = try await context.value
    XCTAssertEqual(result.structuredContent?.objectValue?["mcp_state"], "ready")
    let sessionID = await transport.sessionID
    XCTAssertNotNil(sessionID)

    await client.disconnect()
    await server.stop()
    let stoppedEndpoint = await server.endpoint
    XCTAssertNil(stoppedEndpoint)
  }

  func testTunnelHeaderModeCompletesStrictSDKRoundTripWithoutSecretURL() async throws {
    let secret = String(repeating: "H", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: IntegrationQueries(),
      httpConfiguration: try MCPHTTPConfiguration(headerSecret: secret)
    )
    let endpoint = try await server.start()
    XCTAssertEqual(endpoint.localURL.path, "/mcp")
    XCTAssertFalse(endpoint.localURL.absoluteString.contains(secret))

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [
      MCPHTTPConfiguration.tunnelAuthenticationHeader: secret
    ]
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "codex-bridge-tunnel-header-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }

    let initialized = try await client.connect(transport: transport)
    XCTAssertEqual(initialized.serverInfo.name, "codex-bridge")
    let tools = try await client.listTools()
    XCTAssertEqual(tools.tools.count, MCPToolName.allCases.count)
  }

  func testConcurrentFacadeStopsCompleteBeforeRestart() async throws {
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: IntegrationQueries(),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: String(repeating: "B", count: 43))
    )
    _ = try await server.start()

    async let firstStop: Void = server.stop()
    async let secondStop: Void = server.stop()
    _ = await (firstStop, secondStop)
    let stoppedEndpoint = await server.endpoint
    XCTAssertNil(stoppedEndpoint)

    let restarted = try await server.start()
    XCTAssertGreaterThan(restarted.port, 0)
    await server.stop()
  }

  func testRealLoopbackCancellationReachesTheRunningTool() async throws {
    let probe = CancellationProbe()
    let secret = String(repeating: "C", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: CancellationQueries(probe: probe),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret)
    )
    let endpoint = try await server.start()
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: .ephemeral,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "codex-bridge-cancellation-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }
    _ = try await client.connect(transport: transport)

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPToolName.listModels.rawValue
    )
    let didStart = try await waitUntil { await probe.hasStarted }
    XCTAssertTrue(didStart)
    try await client.cancelRequest(context.requestID, reason: "integration test")
    do {
      _ = try await context.value
      XCTFail("Expected the MCP request to be cancelled.")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected request cancellation error: \(error)")
    }
    let didCancel = try await waitUntil { await probe.wasCancelled }
    XCTAssertTrue(didCancel)

    await client.disconnect()
    await server.stop()
    let stoppedEndpoint = await server.endpoint
    XCTAssertNil(stoppedEndpoint)
  }

  func testRealLoopbackGETCanResumeTheSameSessionAfterDisconnect() async throws {
    let secret = String(repeating: "D", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: IntegrationQueries(),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret)
    )
    let endpoint = try await server.start()
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: .ephemeral,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "codex-bridge-sse-resume-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }
    _ = try await client.connect(transport: transport)
    let reportedSessionID = await transport.sessionID
    let sessionID = try XCTUnwrap(reportedSessionID)

    let firstEventID = try await firstSSEEventID(
      endpoint: endpoint.localURL,
      sessionID: sessionID
    )
    let resumedEventID = try await firstSSEEventID(
      endpoint: endpoint.localURL,
      sessionID: sessionID,
      lastEventID: firstEventID
    )

    XCTAssertNotEqual(firstEventID, resumedEventID)
    let status: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPToolName.bridgeStatus.rawValue
    )
    let statusResult = try await status.value
    XCTAssertEqual(statusResult.isError, false)
  }

  func testDroppedPOSTTerminatesSessionBeforeUnwrittenReplayCanAccumulate() async throws {
    let probe = CancellationProbe(waitsForRelease: true)
    let secret = String(repeating: "E", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: CancellationQueries(probe: probe),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret)
    )
    let endpoint = try await server.start()
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: .ephemeral,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "codex-bridge-dropped-post-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }
    _ = try await client.connect(transport: transport)
    let reportedSessionID = await transport.sessionID
    let sessionID = try XCTUnwrap(reportedSessionID)

    let descriptor = try openSocket(port: endpoint.port)
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen {
        Darwin.close(descriptor)
      }
    }
    let body = Data(
      """
      {"jsonrpc":"2.0","id":"dropped","method":"tools/call","params":{"name":"list_models","arguments":{}}}
      """.utf8
    )
    let requestHead =
      "POST \(endpoint.localURL.path) HTTP/1.1\r\n"
      + "Host: 127.0.0.1:\(endpoint.port)\r\n"
      + "Accept: application/json, text/event-stream\r\n"
      + "Content-Type: application/json\r\n"
      + "MCP-Protocol-Version: \(Version.latest)\r\n"
      + "MCP-Session-Id: \(sessionID)\r\n"
      + "Content-Length: \(body.count)\r\n\r\n"
    let request = Data(requestHead.utf8) + body
    try sendAll(request, descriptor: descriptor)
    let didStart = try await waitUntil { await probe.hasStarted }
    XCTAssertTrue(didStart)
    var reset = linger(l_onoff: 1, l_linger: 0)
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_LINGER,
      &reset,
      socklen_t(MemoryLayout<linger>.size)
    )
    Darwin.close(descriptor)
    descriptorIsOpen = false

    await probe.release()
    let sessionWasRetired = try await waitUntilSessionUnavailable(client)
    XCTAssertTrue(sessionWasRetired)
  }

  private func firstSSEEventID(
    endpoint: URL,
    sessionID: String,
    lastEventID: String? = nil
  ) async throws -> String {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("text/event-stream", forHTTPHeaderField: HTTPHeaderName.accept)
    request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
    request.setValue(Version.latest, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
    if let lastEventID {
      request.setValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
    }

    let (bytes, rawResponse) = try await session.bytes(for: request)
    let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
    XCTAssertEqual(response.statusCode, 200)
    for try await line in bytes.lines {
      guard line.hasPrefix("id:") else { continue }
      return line.dropFirst(3).trimmingCharacters(in: .whitespaces)
    }
    throw MCPIntegrationTestError.missingSSEEventID
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if await predicate() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private func waitUntilSessionUnavailable(_ client: Client) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      do {
        let context: RequestContext<CallTool.Result> = try await client.callTool(
          name: MCPToolName.bridgeStatus.rawValue
        )
        _ = try await context.value
      } catch {
        return true
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private enum MCPIntegrationTestError: Error {
  case missingSSEEventID
}

private actor CancellationProbe {
  private let waitsForRelease: Bool
  private(set) var hasStarted = false
  private(set) var wasCancelled = false
  private var isReleased = false
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  init(waitsForRelease: Bool = false) {
    self.waitsForRelease = waitsForRelease
  }

  func run() async throws -> MCPModelList {
    hasStarted = true
    if waitsForRelease {
      if !isReleased {
        await withCheckedContinuation { releaseWaiter = $0 }
      }
      return MCPModelList(models: [])
    }
    do {
      try await Task.sleep(for: .seconds(30))
      return MCPModelList(models: [])
    } catch is CancellationError {
      wasCancelled = true
      throw CancellationError()
    }
  }

  func release() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

private struct CancellationQueries: BridgeMCPQueries {
  let probe: CancellationProbe
  private let fallback = IntegrationQueries()

  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    try await fallback.statusSnapshot(deadline: deadline)
  }

  func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    try await fallback.listMCPVisibleProjects(cursor: cursor, limit: limit, deadline: deadline)
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    try await fallback.listThreads(
      projectID: projectID,
      cursor: cursor,
      limit: limit,
      search: search,
      deadline: deadline
    )
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    try await fallback.readThread(
      projectID: projectID,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    try await probe.run()
  }
}

private struct IntegrationQueries: BridgeMCPQueries {
  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "0.1.0",
      mcpState: "ready",
      tunnelState: "disconnected",
      executionState: "ready",
      supervisorState: "ready",
      pendingApprovalCount: 0
    )
  }

  func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    MCPProjectPage(projects: [])
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    MCPThreadPage(threads: [])
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    throw BridgeMCPQueryError.threadNotFound
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    MCPModelList(models: [])
  }
}
