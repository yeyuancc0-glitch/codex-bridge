import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

package final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  package typealias InboundIn = HTTPServerRequestPart
  package typealias OutboundOut = HTTPServerResponsePart

  private struct RequestState {
    let head: HTTPRequestHead
    let sessionID: String?
    var body: ByteBuffer
    var byteCount: Int
  }

  private enum InputState {
    case waiting
    case receiving(RequestState)
    case rejecting
    case responding
  }

  private let configuration: MCPHTTPConfiguration
  private let routeBytes: [UInt8]
  private let handler: MCPHTTPRequestHandler
  private let emissionObserver: MCPHTTPEmissionObserver?
  private let admission: MCPHTTPAdmission
  private let writability = MCPHTTPWritability()
  private var inputState = InputState.waiting
  private var requestLease: MCPHTTPRequestLease?
  private var headerTimeout: Scheduled<Void>?
  private var bodyTimeout: Scheduled<Void>?
  private var responseTimeout: Scheduled<Void>?
  private var responseTask: Task<Void, Never>?
  private var activeResponseSessionID: String?
  private var connectionReleased = false
  private var hasSeenRequestHead = false

  package init(
    configuration: MCPHTTPConfiguration,
    handler: @escaping MCPHTTPRequestHandler,
    emissionObserver: MCPHTTPEmissionObserver?,
    admission: MCPHTTPAdmission
  ) {
    self.configuration = configuration
    routeBytes = configuration.routeBytes
    self.handler = handler
    self.emissionObserver = emissionObserver
    self.admission = admission
  }

  package func channelActive(context: ChannelHandlerContext) {
    scheduleHeaderTimeout(context: context)
    let isWritable = context.channel.isWritable
    writability.update(isWritable: isWritable, isOpen: true)
    context.fireChannelActive()
  }

  package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      receiveHead(head, context: context)
    case .body(var body):
      receiveBody(&body, context: context)
    case .end:
      receiveEnd(context: context)
    }
  }

  package func channelWritabilityChanged(context: ChannelHandlerContext) {
    let isWritable = context.channel.isWritable
    let isOpen = context.channel.isActive
    writability.update(
      isWritable: isWritable,
      isOpen: isOpen
    )
    context.fireChannelWritabilityChanged()
  }

  package func channelInactive(context: ChannelHandlerContext) {
    cancelTimeouts()
    responseTask?.cancel()
    if responseTask == nil { releaseRequest() }
    releaseConnection(context.channel)
    writability.update(isWritable: false, isOpen: false)
    context.fireChannelInactive()
  }

  package func errorCaught(context: ChannelHandlerContext, error: any Error) {
    cancelTimeouts()
    responseTask?.cancel()
    if responseTask == nil { releaseRequest() }
    context.close(promise: nil)
  }

  private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    hasSeenRequestHead = true
    NSLog("[MCPHTTP] \(head.method) \(head.uri) headers=\(head.headers.count)")
    guard case .waiting = inputState else {
      context.close(promise: nil)
      return
    }
    headerTimeout?.cancel()
    headerTimeout = nil

    guard head.uri.utf8.count <= configuration.maximumRequestTargetBytes else {
      reject(status: .uriTooLong, context: context)
      return
    }
    let isOAuth = head.method == .GET && isOAuthProtectedResourceRoute(head.uri)
    if !isOAuth {
      guard isExactRoute(head.uri) else {
        reject(status: .notFound, context: context)
        return
      }
      guard hasValidAuthenticationHeader(head.headers) else {
        reject(status: .notFound, context: context)
        return
      }
      guard isAllowedMethod(head.method) else {
        reject(status: .methodNotAllowed, allow: "POST, GET, DELETE", context: context)
        return
      }
    }
    guard aggregateHeaderBytes(head.headers) <= configuration.maximumHeaderBytes else {
      reject(status: .requestHeaderFieldsTooLarge, context: context)
      return
    }
    guard let lease = admission.admitRequest() else {
      reject(status: .tooManyRequests, context: context)
      return
    }
    requestLease = lease

    guard let contentLength = validContentLength(head.headers) else {
      reject(status: .badRequest, context: context)
      return
    }
    guard contentLength <= configuration.maximumRequestBodyBytes else {
      reject(status: .payloadTooLarge, context: context)
      return
    }

    let capacity = min(contentLength, configuration.maximumRequestBodyBytes)
    inputState = .receiving(
      RequestState(
        head: head,
        sessionID: head.headers.first(name: HTTPHeaderName.sessionID),
        body: context.channel.allocator.buffer(capacity: capacity),
        byteCount: 0
      )
    )
    scheduleBodyTimeout(context: context)
  }

  private func receiveBody(_ body: inout ByteBuffer, context: ChannelHandlerContext) {
    guard case .receiving(var request) = inputState else { return }
    let (nextCount, overflowed) = request.byteCount.addingReportingOverflow(body.readableBytes)
    guard !overflowed, nextCount <= configuration.maximumRequestBodyBytes else {
      reject(status: .payloadTooLarge, context: context)
      return
    }
    request.byteCount = nextCount
    request.body.writeBuffer(&body)
    inputState = .receiving(request)
  }

  private func receiveEnd(context: ChannelHandlerContext) {
    switch inputState {
    case .receiving(let request):
      bodyTimeout?.cancel()
      bodyTimeout = nil
      inputState = .responding
      _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
      let channel = context.channel
      let eventLoop = context.eventLoop
      activeResponseSessionID = request.sessionID
      scheduleResponseTimeout(channel: channel, eventLoop: eventLoop)
      let lease = requestLease
      requestLease = nil
      guard let lease else {
        reject(status: .badRequest, context: context)
        return
      }
      if request.head.method == .GET && isOAuthProtectedResourceRoute(request.head.uri) {
        serveOAuthProtectedResource(channel: channel, context: context, lease: lease)
        return
      }
      nonisolated(unsafe) let sendableContext = context
      responseTask = Task {
        await handle(
          request,
          channel: channel,
          eventLoop: eventLoop,
          context: sendableContext,
          lease: lease
        )
      }
    case .rejecting:
      break
    case .waiting, .responding:
      reject(status: .badRequest, context: context)
    }
  }

  private func handle(
    _ state: RequestState,
    channel: any Channel,
    eventLoop: any EventLoop,
    context: ChannelHandlerContext,
    lease: MCPHTTPRequestLease
  ) async {
    defer { lease.release() }
    let request = makeRequest(state)
    var bodyPreview = "none"
    if let data = request.body, data.count > 0 {
      let text = String(data: Data(data.prefix(240)), encoding: .utf8) ?? "?"
      bodyPreview = text.replacingOccurrences(of: "\n", with: " ")
    }
    NSLog(
      "[MCPHTTP] handling \(state.head.method) uri=\(state.head.uri) session=\(state.sessionID ?? "none") body=\(bodyPreview)"
    )
    let response = await handler(request)
    var responsePreview = ""
    if case .data(let data, _) = response {
      let text = String(data: Data(data.prefix(300)), encoding: .utf8) ?? "?"
      responsePreview = " body=" + text.replacingOccurrences(of: "\n", with: " ")
    }
    NSLog("[MCPHTTP] response code=\(response.statusCode)\(responsePreview)")
    let sessionID = state.sessionID ?? responseSessionID(response)
    try? await eventLoop.submit {
      self.activeResponseSessionID = sessionID
    }.get()
    do {
      try await write(
        response,
        sessionID: sessionID,
        version: state.head.version,
        keepAlive: state.head.isKeepAlive,
        channel: channel
      )
      await responseFinished(
        keepAlive: state.head.isKeepAlive,
        eventLoop: eventLoop,
        context: context,
        channel: channel
      )
    } catch {
      let disconnected = Task.isCancelled || !channel.isActive
      if state.head.method == .POST || !disconnected {
        await notifyEmission(sessionID: sessionID, byteCount: 0, kind: .sessionTerminated)
      }
      guard !disconnected else { return }
      try? await channel.close().get()
    }
  }

  private func write(
    _ response: MCP.HTTPResponse,
    sessionID: String?,
    version: HTTPVersion,
    keepAlive: Bool,
    channel: any Channel
  ) async throws {
    switch response {
    case .stream(let stream, let headers):
      try await writeHead(
        statusCode: response.statusCode,
        headers: headers,
        bodyLength: nil,
        version: version,
        keepAlive: keepAlive,
        flush: true,
        channel: channel
      )
      do {
        for try await event in stream {
          guard event.count <= configuration.maximumResponseChunkBytes else {
            throw MCPHTTPWriteError.responseChunkTooLarge
          }
          try Task.checkCancellation()
          try await writability.waitUntilWritable()
          try await writeBody(event, flush: true, channel: channel)
          await notifyEmission(
            sessionID: sessionID,
            byteCount: event.count,
            kind: .streamEvent
          )
        }
      } catch {
        throw error
      }
      try await writeEnd(channel: channel)

    default:
      let body = response.bodyData
      guard (body?.count ?? 0) <= configuration.maximumResponseChunkBytes else {
        throw MCPHTTPWriteError.responseChunkTooLarge
      }
      try await writeHead(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyLength: body?.count ?? 0,
        version: version,
        keepAlive: keepAlive,
        flush: true,
        channel: channel
      )
      if let body, !body.isEmpty {
        try await writeBody(body, flush: true, channel: channel)
      }
      try await writeEnd(channel: channel)
      await notifyEmission(
        sessionID: sessionID,
        byteCount: body?.count ?? 0,
        kind: .responseBody
      )
    }
  }

  private func writeHead(
    statusCode: Int,
    headers: [String: String],
    bodyLength: Int?,
    version: HTTPVersion,
    keepAlive: Bool,
    flush: Bool,
    channel: any Channel
  ) async throws {
    var head = HTTPResponseHead(
      version: version,
      status: HTTPResponseStatus(statusCode: statusCode)
    )
    for (name, value) in headers {
      head.headers.add(name: name, value: value)
    }
    if let bodyLength {
      head.headers.replaceOrAdd(name: "Content-Length", value: String(bodyLength))
    }
    if !keepAlive {
      head.headers.replaceOrAdd(name: "Connection", value: "close")
    }
    let part = HTTPServerResponsePart.head(head)
    if flush {
      try await channel.writeAndFlush(part).get()
    } else {
      try await channel.write(part).get()
    }
  }

  private func writeBody(
    _ data: Data,
    flush: Bool,
    channel: any Channel
  ) async throws {
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    let part = HTTPServerResponsePart.body(.byteBuffer(buffer))
    if flush {
      try await channel.writeAndFlush(part).get()
    } else {
      try await channel.write(part).get()
    }
  }

  private func writeEnd(channel: any Channel) async throws {
    guard !Task.isCancelled, channel.isActive else { return }
    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    nonisolated(unsafe) let sendableSelf = self
    try await channel.eventLoop.submit {
      sendableSelf.responseTimeout?.cancel()
      sendableSelf.responseTimeout = nil
      sendableSelf.activeResponseSessionID = nil
      sendableSelf.inputState = .waiting
      sendableSelf.responseTask = nil
    }.get()
  }

  private func responseFinished(
    keepAlive: Bool,
    eventLoop: any EventLoop,
    context: ChannelHandlerContext,
    channel: any Channel
  ) async {
    guard keepAlive else {
      try? await channel.close().get()
      return
    }
    nonisolated(unsafe) let sendableContext = context
    try? await eventLoop.submit {
      guard sendableContext.channel.isActive else { return }
      _ = sendableContext.channel.setOption(ChannelOptions.autoRead, value: true)
      sendableContext.read()
      self.scheduleHeaderTimeout(context: sendableContext)
    }.get()
  }

  private func makeRequest(_ state: RequestState) -> MCP.HTTPRequest {
    var headers: [String: String] = [:]
    for (name, value) in state.head.headers {
      guard name.lowercased() != MCPHTTPConfiguration.tunnelAuthenticationHeader.lowercased()
      else { continue }
      if let existing = headers[name] {
        headers[name] = "\(existing), \(value)"
      } else {
        headers[name] = value
      }
    }
    let body = state.body.getBytes(at: 0, length: state.body.readableBytes).map(Data.init)
    return MCP.HTTPRequest(
      method: state.head.method.rawValue,
      headers: headers,
      body: body?.isEmpty == true ? nil : body,
      path: state.head.uri
    )
  }

  private func reject(
    status: HTTPResponseStatus,
    allow: String? = nil,
    context: ChannelHandlerContext
  ) {
    cancelTimeouts()
    inputState = .rejecting
    releaseRequest()
    guard hasSeenRequestHead else {
      context.close(promise: nil)
      return
    }
    var head = HTTPResponseHead(version: .http1_1, status: status)
    head.headers.add(name: "Content-Length", value: "0")
    head.headers.add(name: "Connection", value: "close")
    if let allow {
      head.headers.add(name: "Allow", value: allow)
    }
    let channel = context.channel
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  private func isOAuthProtectedResourceRoute(_ uri: String) -> Bool {
    uri == "/.well-known/oauth-protected-resource/mcp"
      || uri == "/.well-known/oauth-protected-resource"
  }

  private func serveOAuthProtectedResource(
    channel: any Channel,
    context: ChannelHandlerContext,
    lease: MCPHTTPRequestLease
  ) {
    defer { lease.release() }
    cancelTimeouts()
    let port = channel.localAddress?.port ?? configuration.port
    let body = """
      {"resource":"http://127.0.0.1:\(port)/mcp","authorization_servers":[],"scopes_supported":["read","write"]}
      """
    let bodyData = Data(body.utf8)
    var head = HTTPResponseHead(version: .http1_1, status: .ok)
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Content-Length", value: "\(bodyData.count)")
    head.headers.add(name: "Connection", value: "close")
    var buffer = channel.allocator.buffer(capacity: bodyData.count)
    buffer.writeBytes(bodyData)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  private func isExactRoute(_ target: String) -> Bool {
    let candidate: [UInt8]
    if configuration.usesHeaderAuthentication {
      let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
      let cleanPath = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
      candidate = Array(cleanPath.utf8)
    } else {
      candidate = Array(target.utf8)
      guard !candidate.contains(63), !candidate.contains(35) else {
        return false
      }
    }
    guard !candidate.contains(37) else {
      return false
    }
    return constantTimeEqual(candidate, routeBytes)
  }

  private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference = lhs.count ^ rhs.count
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= Int(left ^ right)
    }
    return difference == 0
  }

  private func hasValidAuthenticationHeader(_ headers: HTTPHeaders) -> Bool {
    guard let expected = configuration.headerSecret else { return true }
    let values = headers[canonicalForm: MCPHTTPConfiguration.tunnelAuthenticationHeader]
    guard values.count == 1 else { return false }
    return constantTimeEqual(Array(values[0].utf8), Array(expected.utf8))
  }

  private func isAllowedMethod(_ method: HTTPMethod) -> Bool {
    method == .POST || method == .GET || method == .DELETE
  }

  private func aggregateHeaderBytes(_ headers: HTTPHeaders) -> Int {
    headers.reduce(into: 0) { count, header in
      let (nameCount, nameOverflow) = count.addingReportingOverflow(header.name.utf8.count)
      let (total, valueOverflow) = nameCount.addingReportingOverflow(header.value.utf8.count)
      count = nameOverflow || valueOverflow ? Int.max : total
    }
  }

  private func validContentLength(_ headers: HTTPHeaders) -> Int? {
    let values = headers[canonicalForm: "content-length"]
    guard values.count <= 1 else { return nil }
    guard let raw = values.first else { return 0 }
    guard let value = Int(raw), value >= 0 else { return nil }
    return value
  }

  private func scheduleHeaderTimeout(context: ChannelHandlerContext) {
    headerTimeout?.cancel()
    let delay = TimeAmount(configuration.headerDeadline)
    nonisolated(unsafe) let sendableContext = context
    headerTimeout = context.eventLoop.scheduleTask(in: delay) { [weak self] in
      guard let self, case .waiting = self.inputState else { return }
      self.cancelTimeouts()
      self.releaseRequest()
      sendableContext.close(promise: nil)
    }
  }

  private func scheduleBodyTimeout(context: ChannelHandlerContext) {
    bodyTimeout?.cancel()
    let delay = TimeAmount(configuration.bodyDeadline)
    nonisolated(unsafe) let sendableContext = context
    bodyTimeout = context.eventLoop.scheduleTask(in: delay) { [weak self] in
      guard let self, case .receiving = self.inputState else { return }
      self.reject(status: .requestTimeout, context: sendableContext)
    }
  }

  private func scheduleResponseTimeout(
    channel: any Channel,
    eventLoop: any EventLoop
  ) {
    responseTimeout?.cancel()
    let delay = TimeAmount(configuration.responseDeadline)
    responseTimeout = eventLoop.scheduleTask(in: delay) { [weak self] in
      guard let self, case .responding = self.inputState else { return }
      let sessionID = self.activeResponseSessionID
      self.responseTask?.cancel()
      Task {
        await self.notifyEmission(
          sessionID: sessionID,
          byteCount: 0,
          kind: .sessionTerminated
        )
        try? await channel.close().get()
      }
    }
  }

  private func cancelTimeouts() {
    headerTimeout?.cancel()
    bodyTimeout?.cancel()
    responseTimeout?.cancel()
    headerTimeout = nil
    bodyTimeout = nil
    responseTimeout = nil
  }

  private func releaseRequest() {
    let lease = requestLease
    requestLease = nil
    lease?.release()
  }

  private func releaseConnection(_ channel: any Channel) {
    guard !connectionReleased else { return }
    connectionReleased = true
    admission.unregister(channel)
  }

  private func notifyEmission(
    sessionID: String?,
    byteCount: Int,
    kind: MCPHTTPEmission.Kind
  ) async {
    guard let emissionObserver else { return }
    let emission = MCPHTTPEmission(sessionID: sessionID, byteCount: byteCount, kind: kind)
    await emissionObserver(emission)
  }

  private func responseSessionID(_ response: MCP.HTTPResponse) -> String? {
    response.headers.first { name, _ in
      name.caseInsensitiveCompare(HTTPHeaderName.sessionID) == .orderedSame
    }?.value
  }
}

package final class MCPHTTPWritability: @unchecked Sendable {
  private let lock = NSLock()
  private var isWritable = true
  private var isOpen = true
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  func update(isWritable: Bool, isOpen: Bool) {
    var pending: [CheckedContinuation<Void, any Error>] = []
    var error: (any Error)?
    lock.withLock {
      guard self.isOpen else { return }
      self.isWritable = isWritable
      self.isOpen = isOpen
      guard isWritable || !isOpen else { return }
      pending = Array(waiters.values)
      waiters.removeAll(keepingCapacity: true)
      if !isOpen {
        error = MCPHTTPWriteError.channelClosed
      }
    }
    for waiter in pending {
      if let error {
        waiter.resume(throwing: error)
      } else {
        waiter.resume()
      }
    }
  }

  func waitUntilWritable() async throws {
    let identifier = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var outcome: Result<Void, any Error>?
        lock.withLock {
          if Task.isCancelled {
            outcome = .failure(CancellationError())
          } else if !isOpen {
            outcome = .failure(MCPHTTPWriteError.channelClosed)
          } else if isWritable {
            outcome = .success(())
          } else {
            waiters[identifier] = continuation
          }
        }
        if let outcome {
          continuation.resume(with: outcome)
        }
      }
    } onCancel: {
      self.cancelWaiter(identifier)
    }
  }

  private func cancelWaiter(_ identifier: UUID) {
    let waiter = lock.withLock {
      waiters.removeValue(forKey: identifier)
    }
    if let waiter {
      waiter.resume(throwing: CancellationError())
    }
  }
}

private enum MCPHTTPWriteError: Error {
  case channelClosed
  case responseChunkTooLarge
}

extension TimeAmount {
  fileprivate init(_ duration: Duration) {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let attoseconds = components.attoseconds / 1_000_000_000
    let nanoseconds = seconds.overflow ? Int64.max : seconds.partialValue
    let (combined, overflowed) = nanoseconds.addingReportingOverflow(Int64(attoseconds))
    self = .nanoseconds(overflowed ? Int64.max : combined)
  }
}
