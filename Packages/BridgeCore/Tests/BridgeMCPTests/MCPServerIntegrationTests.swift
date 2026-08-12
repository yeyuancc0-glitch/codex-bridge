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
