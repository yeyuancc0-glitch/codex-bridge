import Foundation
import XCTest

@testable import BridgeACP

final class ACPRequestBrokerTests: XCTestCase {
  func testRequestResolvesWithResponseAndSequenceBarrier() async throws {
    let transport = TestACPTransport()
    let broker = ACPRequestBroker(transport: transport)
    let request = Task {
      try await broker.request(
        method: "initialize",
        params: .object(["version": .integer(1)])
      )
    }

    try await waitForSentFrame(on: transport)
    let sentMessages = await transport.sentMessages()
    let sent = try XCTUnwrap(sentMessages.first)
    let requestID = try XCTUnwrap(sent.id)
    XCTAssertFalse(
      broker.resolve(
        id: .integer(999),
        result: .object(["unknown": .bool(true)]),
        error: nil,
        eventSequenceBarrier: 6
      )
    )
    XCTAssertTrue(
      broker.resolve(
        id: requestID,
        result: .object(["ok": .bool(true)]),
        error: nil,
        eventSequenceBarrier: 7
      )
    )
    XCTAssertFalse(
      broker.resolve(
        id: requestID,
        result: .object(["duplicate": .bool(true)]),
        error: nil,
        eventSequenceBarrier: 8
      )
    )

    let response = try await request.value
    XCTAssertEqual(response.value, .object(["ok": .bool(true)]))
    XCTAssertEqual(response.eventSequenceBarrier, 7)
    await broker.close()
  }

  func testRequestTimesOutAndDoesNotResolveAfterwards() async throws {
    let transport = TestACPTransport()
    let broker = ACPRequestBroker(transport: transport, requestTimeout: .milliseconds(20))

    do {
      _ = try await broker.request(method: "slow", params: .object([:]))
      XCTFail("Expected request timeout")
    } catch {
      XCTAssertEqual(error as? ACPError, .requestTimedOut)
    }

    let sentMessages = await transport.sentMessages()
    let sent = try XCTUnwrap(sentMessages.first)
    broker.resolve(
      id: try XCTUnwrap(sent.id),
      result: .object(["late": .bool(true)]),
      error: nil,
      eventSequenceBarrier: 1
    )
    await broker.close()
  }

  func testCloseFailsPendingRequestAndClosesTransport() async throws {
    let transport = TestACPTransport()
    let broker = ACPRequestBroker(transport: transport)
    let request = Task {
      try await broker.request(method: "blocked", params: .object([:]))
    }

    try await waitForSentFrame(on: transport)
    await broker.close()

    do {
      _ = try await request.value
      XCTFail("Expected close to fail the request")
    } catch {
      XCTAssertEqual(error as? ACPError, .transportClosed)
    }
    let closed = await transport.isClosed()
    XCTAssertTrue(closed)
  }

  private func waitForSentFrame(
    on transport: TestACPTransport,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if !(await transport.sentMessages()).isEmpty { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for request frame", file: file, line: line)
  }
}

actor TestACPTransport: ACPTransport {
  nonisolated let incoming: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private var sent: [ACPWireMessage] = []
  private var closed = false

  init() {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(256)
    )
    incoming = pair.stream
    continuation = pair.continuation
  }

  func send(_ frame: Data) async throws {
    guard !closed else { throw ACPError.transportClosed }
    sent.append(try JSONDecoder().decode(ACPWireMessage.self, from: frame))
  }

  func sentMessages() -> [ACPWireMessage] {
    sent
  }

  func isClosed() -> Bool {
    closed
  }

  func close() async {
    guard !closed else { return }
    closed = true
    continuation.finish()
  }
}
