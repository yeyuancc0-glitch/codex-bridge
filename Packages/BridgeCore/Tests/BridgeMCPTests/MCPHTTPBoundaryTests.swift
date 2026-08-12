import Darwin
import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPHTTPBoundaryTests: XCTestCase {
  private let secret = String(repeating: "A", count: 43)

  func testBindsIPv4LoopbackAndForwardsOnlyExactRawRoute() async throws {
    let calls = CallCounter()
    let emissions = EmissionRecorder()
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(pathSecret: secret),
      handler: { request in
        await calls.record(path: request.path)
        return .data(Data("ready".utf8), headers: ["Content-Type": "text/plain"])
      },
      emissionObserver: { emission in
        await emissions.record(emission)
      }
    )
    addTeardownBlock { await listener.stop() }

    let endpoint = try await listener.start()
    XCTAssertEqual(endpoint.host, "127.0.0.1")
    XCTAssertGreaterThan(endpoint.port, 0)

    let response = try await rawRequest(
      port: endpoint.port,
      target: route,
      method: "POST",
      headers: ["MCP-Session-Id": "session-fixture"],
      body: Data("{}".utf8)
    )
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.body, Data("ready".utf8))
    let callSnapshot = await calls.snapshot()
    XCTAssertEqual(callSnapshot.count, 1)
    XCTAssertEqual(callSnapshot.lastPath, route)

    let emission = await emissions.firstEvent()
    XCTAssertEqual(emission.sessionID, "session-fixture")
    XCTAssertEqual(emission.byteCount, 5)
    XCTAssertEqual(emission.kind, .responseBody)
    XCTAssertFalse(String(describing: emission).contains(secret))

    await listener.stop()
    let stoppedMetrics = await listener.metrics()
    XCTAssertEqual(stoppedMetrics, MCPHTTPMetrics(activeConnections: 0, activeRequests: 0))
  }

  func testWrongMissingQueryAndPercentEncodedRoutesReturnEmpty404BeforeHandler() async throws {
    let calls = CallCounter()
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(pathSecret: secret),
      handler: { request in
        await calls.record(path: request.path)
        return .ok()
      }
    )
    addTeardownBlock { await listener.stop() }
    let endpoint = try await listener.start()

    let invalidTargets = [
      "/mcp",
      "/mcp/\(String(repeating: "B", count: 43))",
      "\(route)?probe=1",
      "/mcp/%41\(String(repeating: "A", count: 42))",
    ]
    for target in invalidTargets {
      let response = try await rawRequest(
        port: endpoint.port,
        target: target,
        method: "POST",
        body: Data("not-json".utf8)
      )
      XCTAssertEqual(response.statusCode, 404)
      XCTAssertTrue(response.body.isEmpty)
    }
    let callSnapshot = await calls.snapshot()
    XCTAssertEqual(callSnapshot.count, 0)
  }

  func testMethodAndFixedAndChunkedBodyLimitsFailClosed() async throws {
    let calls = CallCounter()
    let maximumBodyBytes = 1_024
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(
        pathSecret: secret,
        maximumRequestBodyBytes: maximumBodyBytes
      ),
      handler: { request in
        await calls.record(path: request.path)
        return .ok()
      }
    )
    addTeardownBlock { await listener.stop() }
    let endpoint = try await listener.start()

    let methodResponse = try await rawRequest(
      port: endpoint.port,
      target: route,
      method: "PUT"
    )
    XCTAssertEqual(methodResponse.statusCode, 405)
    XCTAssertEqual(methodResponse.headers["allow"], "POST, GET, DELETE")

    let fixedResponse = try await rawRequest(
      port: endpoint.port,
      target: route,
      method: "POST",
      declaredContentLength: maximumBodyBytes + 1
    )
    XCTAssertEqual(fixedResponse.statusCode, 413)

    let chunkedResponse = try await rawChunkedRequest(
      port: endpoint.port,
      target: route,
      chunks: [Data(repeating: 7, count: maximumBodyBytes + 1)]
    )
    XCTAssertEqual(chunkedResponse.statusCode, 413)
    let callSnapshot = await calls.snapshot()
    XCTAssertEqual(callSnapshot.count, 0)
  }

  func testGlobalRequestAdmissionAndConnectionCleanupUseRealSockets() async throws {
    let gate = RequestGate()
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(
        pathSecret: secret,
        maximumConnections: 4,
        maximumActiveRequests: 1
      ),
      handler: { _ in
        await gate.block()
        return .data(Data("done".utf8))
      }
    )
    addTeardownBlock {
      await gate.release()
      await listener.stop()
    }
    let endpoint = try await listener.start()

    let target = route
    async let first = performURLRequest(port: endpoint.port, target: target)
    await gate.waitUntilEntered()
    let second = try await performURLRequest(port: endpoint.port, target: target)
    XCTAssertEqual(second.statusCode, 429)

    await gate.release()
    let firstResponse = try await first
    XCTAssertEqual(firstResponse.statusCode, 200)
    XCTAssertEqual(firstResponse.body, Data("done".utf8))

    try await waitForCleanup(listener)
    let cleanedMetrics = await listener.metrics()
    XCTAssertEqual(cleanedMetrics, MCPHTTPMetrics(activeConnections: 0, activeRequests: 0))
  }

  func testBodyDeadlineReturns408AndReleasesAdmission() async throws {
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(
        pathSecret: secret,
        bodyDeadline: .milliseconds(80)
      ),
      handler: { _ in .ok() }
    )
    addTeardownBlock { await listener.stop() }
    let endpoint = try await listener.start()

    let request = Data(
      "POST \(route) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
        .utf8
    )
    let response = try await sendRaw(port: endpoint.port, fragments: [request])
    XCTAssertEqual(response.statusCode, 408)
    try await waitForCleanup(listener)
    let cleanedMetrics = await listener.metrics()
    XCTAssertEqual(cleanedMetrics.activeRequests, 0)
  }

  func testResponseDeadlineTerminatesTheCorrelatedSession() async throws {
    let gate = RequestGate()
    let emissions = EmissionRecorder()
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(
        pathSecret: secret,
        responseDeadline: .milliseconds(80)
      ),
      handler: { _ in
        await gate.block()
        return .ok()
      },
      emissionObserver: { emission in
        await emissions.record(emission)
      }
    )
    addTeardownBlock {
      await gate.release()
      await listener.stop()
    }
    let endpoint = try await listener.start()
    let target = route
    let request = Task {
      try? await performURLRequest(
        port: endpoint.port,
        target: target,
        sessionID: "deadline-session"
      )
    }

    await gate.waitUntilEntered()
    let emission = await emissions.firstEvent()
    XCTAssertEqual(emission.sessionID, "deadline-session")
    XCTAssertEqual(emission.kind, .sessionTerminated)

    await gate.release()
    _ = await request.value
    try await waitForCleanup(listener)
    let cleanedMetrics = await listener.metrics()
    XCTAssertEqual(cleanedMetrics.activeRequests, 0)
  }

  func testConcurrentStartsShareOneBindAndConcurrentStopsWaitForShutdown() async throws {
    let listener = MCPHTTPListener(
      configuration: try MCPHTTPConfiguration(pathSecret: secret),
      handler: { _ in .ok() }
    )
    addTeardownBlock { await listener.stop() }

    async let first = listener.start()
    async let second = listener.start()
    let endpoints = try await [first, second]
    XCTAssertEqual(endpoints[0], endpoints[1])

    async let firstStop: Void = listener.stop()
    async let secondStop: Void = listener.stop()
    _ = await (firstStop, secondStop)
    let stoppedEndpoint = await listener.boundEndpoint
    XCTAssertNil(stoppedEndpoint)
    let metrics = await listener.metrics()
    XCTAssertEqual(metrics, MCPHTTPMetrics(activeConnections: 0, activeRequests: 0))
  }

  func testWritabilityCancellationAndCloseCannotLeakOrReopenWaiters() async {
    let cancelledState = MCPHTTPWritability()
    cancelledState.update(isWritable: false, isOpen: true)
    let cancelledWaiter = Task {
      try await cancelledState.waitUntilWritable()
    }
    await Task.yield()
    cancelledWaiter.cancel()
    do {
      try await cancelledWaiter.value
      XCTFail("Expected the cancelled waiter to finish.")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected cancellation error: \(error)")
    }

    let closedState = MCPHTTPWritability()
    closedState.update(isWritable: false, isOpen: true)
    let closedWaiter = Task {
      try await closedState.waitUntilWritable()
    }
    await Task.yield()
    closedState.update(isWritable: false, isOpen: false)
    closedState.update(isWritable: true, isOpen: true)
    do {
      try await closedWaiter.value
      XCTFail("Expected channel close to finish the waiter.")
    } catch {
    }
    do {
      try await closedState.waitUntilWritable()
      XCTFail("A closed channel must never reopen.")
    } catch {
    }
  }

  private var route: String {
    "/mcp/\(secret)"
  }

  private func rawRequest(
    port: Int,
    target: String,
    method: String,
    headers: [String: String] = [:],
    body: Data? = nil,
    declaredContentLength: Int? = nil
  ) async throws -> RawHTTPResponse {
    var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n"
    for (name, value) in headers {
      head += "\(name): \(value)\r\n"
    }
    if let declaredContentLength {
      head += "Content-Length: \(declaredContentLength)\r\n"
    } else if let body {
      head += "Content-Length: \(body.count)\r\n"
    }
    head += "\r\n"
    var fragments = [Data(head.utf8)]
    if let body {
      fragments.append(body)
    }
    return try await sendRaw(port: port, fragments: fragments)
  }

  private func rawChunkedRequest(
    port: Int,
    target: String,
    chunks: [Data]
  ) async throws -> RawHTTPResponse {
    let head = Data(
      "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
        .utf8
    )
    var fragments = [head]
    for chunk in chunks {
      fragments.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
      fragments.append(chunk)
      fragments.append(Data("\r\n".utf8))
    }
    fragments.append(Data("0\r\n\r\n".utf8))
    return try await sendRaw(port: port, fragments: fragments)
  }

  private func sendRaw(port: Int, fragments: [Data]) async throws -> RawHTTPResponse {
    try await Task.detached {
      let descriptor = try openSocket(port: port)
      defer { Darwin.close(descriptor) }
      for fragment in fragments {
        try sendAll(fragment, descriptor: descriptor)
      }
      return try readResponse(descriptor: descriptor)
    }.value
  }

  private func waitForCleanup(_ listener: MCPHTTPListener) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await listener.metrics() != MCPHTTPMetrics(activeConnections: 0, activeRequests: 0) {
      guard clock.now < deadline else { return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor CallCounter {
  private(set) var count = 0
  private(set) var lastPath: String?

  func record(path: String?) {
    count += 1
    lastPath = path
  }

  func snapshot() -> (count: Int, lastPath: String?) {
    (count, lastPath)
  }
}

private actor EmissionRecorder {
  private var events: [MCPHTTPEmission] = []
  private var waiters: [CheckedContinuation<MCPHTTPEmission, Never>] = []

  func record(_ event: MCPHTTPEmission) {
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume(returning: event)
    } else {
      events.append(event)
    }
  }

  func firstEvent() async -> MCPHTTPEmission {
    if !events.isEmpty {
      return events.removeFirst()
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private actor RequestGate {
  private var entered = false
  private var released = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func block() async {
    entered = true
    let pending = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
    if released { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      enteredWaiters.append(continuation)
    }
  }

  func release() {
    guard !released else { return }
    released = true
    let pending = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

private struct RawHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
}

private enum SocketTestError: Error {
  case socket(Int32)
  case connect(Int32)
  case send(Int32)
  case receive(Int32)
  case malformedResponse
}

private func performURLRequest(
  port: Int,
  target: String,
  sessionID: String? = nil
) async throws -> RawHTTPResponse {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = 3
  configuration.timeoutIntervalForResource = 3
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else {
    throw SocketTestError.malformedResponse
  }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.httpBody = Data("{}".utf8)
  request.setValue("close", forHTTPHeaderField: "Connection")
  if let sessionID {
    request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
  }
  let (body, rawResponse) = try await session.data(for: request)
  guard let response = rawResponse as? HTTPURLResponse else {
    throw SocketTestError.malformedResponse
  }
  return RawHTTPResponse(
    statusCode: response.statusCode,
    headers: [:],
    body: body
  )
}

func openSocket(port: Int) throws -> Int32 {
  let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw SocketTestError.socket(errno) }

  var noSignal: Int32 = 1
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_NOSIGPIPE,
    &noSignal,
    socklen_t(MemoryLayout<Int32>.size)
  )
  var timeout = timeval(tv_sec: 3, tv_usec: 0)
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
      Darwin.connect(
        descriptor,
        socketAddress,
        socklen_t(MemoryLayout<sockaddr_in>.size)
      )
    }
  }
  guard result == 0 else {
    let failure = errno
    Darwin.close(descriptor)
    throw SocketTestError.connect(failure)
  }
  return descriptor
}

func sendAll(_ data: Data, descriptor: Int32) throws {
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
      guard result > 0 else { throw SocketTestError.send(errno) }
      sent += result
    }
  }
}

private func readResponse(descriptor: Int32) throws -> RawHTTPResponse {
  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while true {
    let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
    if count == 0 { break }
    guard count > 0 else {
      if errno == EINTR { continue }
      throw SocketTestError.receive(errno)
    }
    response.append(buffer, count: count)
    if let parsed = try parseCompleteResponse(response) {
      return parsed
    }
  }

  guard let parsed = try parseCompleteResponse(response) else {
    throw SocketTestError.malformedResponse
  }
  return parsed
}

private func parseCompleteResponse(_ response: Data) throws -> RawHTTPResponse? {
  let separator = Data("\r\n\r\n".utf8)
  guard let range = response.range(of: separator) else {
    return nil
  }
  let head = String(decoding: response[..<range.lowerBound], as: UTF8.self)
  let lines = head.components(separatedBy: "\r\n")
  guard
    let statusLine = lines.first,
    let rawStatus = statusLine.split(separator: " ").dropFirst().first,
    let statusCode = Int(rawStatus)
  else {
    throw SocketTestError.malformedResponse
  }
  var headers: [String: String] = [:]
  for line in lines.dropFirst() {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let name = line[..<colon].lowercased()
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    headers[name] = value
  }
  let expectedBodyLength = Int(headers["content-length"] ?? "")
  guard let expectedBodyLength else {
    throw SocketTestError.malformedResponse
  }
  let availableBodyLength = response.distance(from: range.upperBound, to: response.endIndex)
  guard availableBodyLength >= expectedBodyLength else { return nil }
  let bodyEnd = response.index(range.upperBound, offsetBy: expectedBodyLength)
  return RawHTTPResponse(
    statusCode: statusCode,
    headers: headers,
    body: response[range.upperBound..<bodyEnd]
  )
}
