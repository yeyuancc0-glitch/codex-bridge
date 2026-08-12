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

  private func makeRegistry(
    port: Int,
    limits: MCPSessionRegistry.Limits = .init()
  ) -> MCPSessionRegistry {
    MCPSessionRegistry(boundPort: port, limits: limits) { _ in
      Self.makeServer()
    }
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
