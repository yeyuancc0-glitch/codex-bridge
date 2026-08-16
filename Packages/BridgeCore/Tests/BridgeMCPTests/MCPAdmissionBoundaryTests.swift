import Darwin
import Foundation
import MCP
import XCTest

@testable import BridgeMCP

/// Completion evidence for FOLLOW_UP_PLAN.md section 8: MCP pressure and
/// cancellation. Covers the 8/2 tool admission ceiling and the slow-reader
/// backpressure path that the existing MCPHTTPBoundaryTests did not exercise.
final class MCPAdmissionBoundaryTests: XCTestCase {
  private let secret = String(repeating: "A", count: 43)

  // MARK: - 8/2 tool admission limits

  func testConcurrentGlobalAdmissionRejectsBeyondEightDistinctSessions() async {
    let admission = MCPToolAdmission()
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for index in 0..<16 {
        group.addTask {
          await admission.acquire(sessionID: "session-\(index)")
        }
      }
      var collected: [Bool] = []
      for await acquired in group {
        collected.append(acquired)
      }
      return collected
    }

    XCTAssertEqual(results.filter { $0 }.count, 8)
    XCTAssertEqual(results.filter { !$0 }.count, 8)

    // Releasing the eight holders must return the global counter to zero.
    for index in 0..<8 {
      await admission.release(sessionID: "session-\(index)")
    }
    let reacquired = await admission.acquire(sessionID: "session-after-release")
    XCTAssertTrue(reacquired)
  }

  func testConcurrentPerSessionAdmissionRejectsBeyondTwoForSameSession() async {
    let admission = MCPToolAdmission()
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<6 {
        group.addTask {
          await admission.acquire(sessionID: "shared-session")
        }
      }
      var collected: [Bool] = []
      for await acquired in group {
        collected.append(acquired)
      }
      return collected
    }

    XCTAssertEqual(results.filter { $0 }.count, 2)
    XCTAssertEqual(results.filter { !$0 }.count, 4)

    await admission.release(sessionID: "shared-session")
    await admission.release(sessionID: "shared-session")
    let reacquired = await admission.acquire(sessionID: "shared-session")
    XCTAssertTrue(reacquired)
  }

  func testFullReleaseDrainsEveryCounterWithoutPermanentLeak() async {
    let admission = MCPToolAdmission()

    for _ in 0..<4 {
      // Six distinct sessions plus two shared-session slots = exactly 8 global.
      for index in 0..<6 {
        let acquired = await admission.acquire(sessionID: "session-\(index)")
        XCTAssertTrue(acquired)
      }
      let firstShared = await admission.acquire(sessionID: "shared")
      let secondShared = await admission.acquire(sessionID: "shared")
      XCTAssertTrue(firstShared)
      XCTAssertTrue(secondShared)

      // Global full: the ninth distinct session is rejected.
      let globalOverflow = await admission.acquire(sessionID: "overflow")
      XCTAssertFalse(globalOverflow)
      // Per-session full: the third shared slot is rejected.
      let sharedOverflow = await admission.acquire(sessionID: "shared")
      XCTAssertFalse(sharedOverflow)

      // Release all eight; the extra shared release must be an idempotent no-op.
      for index in 0..<6 {
        await admission.release(sessionID: "session-\(index)")
      }
      await admission.release(sessionID: "shared")
      await admission.release(sessionID: "shared")
      await admission.release(sessionID: "shared")
    }

    // A fresh fill reaches the exact same boundary, proving no residual leak.
    for index in 0..<8 {
      let acquired = await admission.acquire(sessionID: "final-\(index)")
      XCTAssertTrue(acquired)
    }
    let overflow = await admission.acquire(sessionID: "final-overflow")
    XCTAssertFalse(overflow)
  }

  // MARK: - Slow-reader backpressure

  func testSlowReaderBackpressureDoesNotBufferUnboundedlyAndDrainsAfterResume() async throws {
    let chunkSize = 32 * 1_024
    let chunkCount = 48
    let emissions = BoundaryEmissionRecorder()
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(
        pathSecret: secret,
        maximumResponseChunkBytes: 64 * 1_024
      ),
      handler: { _ in
        let stream = AsyncThrowingStream<Data, Error> { continuation in
          let chunk = Data(repeating: 0x5A, count: chunkSize)
          for _ in 0..<chunkCount {
            continuation.yield(chunk)
          }
          continuation.finish()
        }
        return .stream(stream, headers: ["Content-Type": "application/octet-stream"])
      },
      emissionObserver: { emission in
        await emissions.record(emission)
      }
    )
    addTeardownBlock { await listener.stop() }
    let endpoint = try await listener.start()

    let descriptor = try openBoundarySocket(port: endpoint.port)
    defer { Darwin.close(descriptor) }

    let request = Data(
      "POST /mcp/\(secret) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        .utf8
    )
    try sendBoundaryAll(request, descriptor: descriptor)

    // Wait for the first chunk, then let the server try to keep writing while
    // the client reads nothing. It must block, not buffer the whole stream.
    try await waitUntil { await emissions.streamEventCount > 0 }
    try await Task.sleep(for: .milliseconds(300))
    let blockedCount = await emissions.streamEventCount
    let blockedMetrics = await listener.metrics()
    XCTAssertEqual(blockedMetrics.activeRequests, 1)
    XCTAssertLessThan(blockedCount, chunkCount)

    // Resuming reads must deliver the complete body and drain all state.
    let response = try readBoundaryResponse(descriptor: descriptor)
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.body.count, chunkSize * chunkCount)
    try await waitUntil {
      await listener.metrics() == MCPHTTPMetrics(activeConnections: 0, activeRequests: 0)
    }
    let finalStreamEventCount = await emissions.streamEventCount
    XCTAssertEqual(finalStreamEventCount, chunkCount)
  }
}

// MARK: - Shared helpers

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()) {
    guard clock.now < deadline else {
      throw BoundaryTestError.timeout
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private actor BoundaryEmissionRecorder {
  private var events: [MCPHTTPEmission] = []

  var streamEventCount: Int {
    events.filter { $0.kind == .streamEvent }.count
  }

  func record(_ emission: MCPHTTPEmission) {
    events.append(emission)
  }
}

// MARK: - Raw socket plumbing

private struct BoundaryHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
}

private enum BoundaryTestError: Error {
  case socket(Int32)
  case connect(Int32)
  case send(Int32)
  case receive(Int32)
  case malformedResponse
  case timeout
}

private func openBoundarySocket(port: Int) throws -> Int32 {
  let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw BoundaryTestError.socket(errno) }

  var noSignal: Int32 = 1
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_NOSIGPIPE,
    &noSignal,
    socklen_t(MemoryLayout<Int32>.size)
  )

  // A tiny receive window forces server-side backpressure quickly and makes
  // the "did not buffer the whole stream" assertion deterministic.
  var receiveBuffer: Int32 = 4 * 1_024
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_RCVBUF,
    &receiveBuffer,
    socklen_t(MemoryLayout<Int32>.size)
  )

  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_RCVTIMEO,
    &timeout,
    socklen_t(MemoryLayout<timeval>.size)
  )

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(port).bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard result == 0 else {
    let failure = errno
    Darwin.close(descriptor)
    throw BoundaryTestError.connect(failure)
  }
  return descriptor
}

private func sendBoundaryAll(_ data: Data, descriptor: Int32) throws {
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else { return }
    var sent = 0
    while sent < rawBuffer.count {
      let result = Darwin.send(
        descriptor,
        baseAddress.advanced(by: sent),
        rawBuffer.count - sent,
        0
      )
      if result < 0, errno == EPIPE || errno == ECONNRESET {
        return
      }
      guard result > 0 else { throw BoundaryTestError.send(errno) }
      sent += result
    }
  }
}

private func readBoundaryResponse(descriptor: Int32) throws -> BoundaryHTTPResponse {
  var all = Data()
  var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
  while true {
    let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
    if count == 0 { break }
    guard count > 0 else {
      if errno == EINTR { continue }
      throw BoundaryTestError.receive(errno)
    }
    all.append(buffer, count: count)
  }
  return try parseBoundaryResponse(all)
}

private func parseBoundaryResponse(_ data: Data) throws -> BoundaryHTTPResponse {
  let separator = Data("\r\n\r\n".utf8)
  guard let headerRange = data.range(of: separator) else {
    throw BoundaryTestError.malformedResponse
  }
  let headText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
  let lines = headText.components(separatedBy: "\r\n")
  guard
    let statusLine = lines.first,
    let rawStatus = statusLine.split(separator: " ").dropFirst().first,
    let statusCode = Int(rawStatus)
  else {
    throw BoundaryTestError.malformedResponse
  }

  var headers: [String: String] = [:]
  for line in lines.dropFirst() {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let name = line[..<colon].lowercased()
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    headers[name] = value
  }

  let remaining = data[headerRange.upperBound...]
  let body: Data
  if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
    body = try decodeChunked(remaining)
  } else if let length = Int(headers["content-length"] ?? "") {
    body = Data(remaining.prefix(length))
  } else {
    body = remaining
  }
  return BoundaryHTTPResponse(statusCode: statusCode, headers: headers, body: body)
}

private func decodeChunked(_ data: Data) throws -> Data {
  var body = Data()
  var offset = data.startIndex
  while offset < data.endIndex {
    let sizeLineEnd = try findCRLF(in: data, from: offset)
    let sizeLine = String(decoding: data[offset..<sizeLineEnd.lowerBound], as: UTF8.self)
    let hex = sizeLine.split(separator: ";").first ?? ""
    guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
      throw BoundaryTestError.malformedResponse
    }
    guard size > 0 else { return body }
    let chunkStart = sizeLineEnd.upperBound
    let chunkEnd = data.index(chunkStart, offsetBy: size)
    guard chunkEnd <= data.endIndex else {
      throw BoundaryTestError.malformedResponse
    }
    body.append(contentsOf: data[chunkStart..<chunkEnd])
    offset = data.index(chunkEnd, offsetBy: 2)
  }
  return body
}

private func findCRLF(
  in data: Data,
  from start: Data.Index
) throws -> (lowerBound: Data.Index, upperBound: Data.Index) {
  let crlf = Data("\r\n".utf8)
  guard let range = data[start...].range(of: crlf) else {
    throw BoundaryTestError.malformedResponse
  }
  return (range.lowerBound, range.upperBound)
}
