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
  private var requestAdmitted = false
  private var headerTimeout: Scheduled<Void>?
  private var bodyTimeout: Scheduled<Void>?
  private var responseTimeout: Scheduled<Void>?
  private var responseTask: Task<Void, Never>?
  private var activeResponseSessionID: String?
  private var connectionReleased = false

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
    Task { await writability.update(isWritable: isWritable, isOpen: true) }
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
    Task {
      await writability.update(
        isWritable: isWritable,
        isOpen: isOpen
      )
    }
    context.fireChannelWritabilityChanged()
  }

  package func channelInactive(context: ChannelHandlerContext) {
    cancelTimeouts()
    responseTask?.cancel()
    releaseRequest()
    releaseConnection(context.channel)
    Task { await writability.update(isWritable: false, isOpen: false) }
    context.fireChannelInactive()
  }

  package func errorCaught(context: ChannelHandlerContext, error: any Error) {
    cancelTimeouts()
    responseTask?.cancel()
    context.close(promise: nil)
  }

  private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    guard case .waiting = inputState else {
      reject(status: .badRequest, context: context)
      return
    }
    headerTimeout?.cancel()
    headerTimeout = nil

    guard head.uri.utf8.count <= configuration.maximumRequestTargetBytes else {
      reject(status: .uriTooLong, context: context)
      return
    }
    guard isExactRoute(head.uri) else {
      reject(status: .notFound, context: context)
      return
    }
    guard isAllowedMethod(head.method) else {
      reject(status: .methodNotAllowed, allow: "POST, GET, DELETE", context: context)
      return
    }
    guard aggregateHeaderBytes(head.headers) <= configuration.maximumHeaderBytes else {
      reject(status: .requestHeaderFieldsTooLarge, context: context)
      return
    }
    guard admission.admitRequest() else {
      reject(status: .tooManyRequests, context: context)
      return
    }
    requestAdmitted = true

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
      let channel = context.channel
      let eventLoop = context.eventLoop
      activeResponseSessionID = request.sessionID
      scheduleResponseTimeout(channel: channel, eventLoop: eventLoop)
      nonisolated(unsafe) let sendableContext = context
      responseTask = Task {
        await handle(
          request,
          channel: channel,
          eventLoop: eventLoop,
          context: sendableContext
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
    context: ChannelHandlerContext
  ) async {
    let request = makeRequest(state)
    let response = await handler(request)
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
      await notifyEmission(sessionID: sessionID, byteCount: 0, kind: .sessionTerminated)
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
    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
  }

  private func responseFinished(
    keepAlive: Bool,
    eventLoop: any EventLoop,
    context: ChannelHandlerContext,
    channel: any Channel
  ) async {
    guard keepAlive else {
      try? await eventLoop.submit {
        self.responseTimeout?.cancel()
        self.responseTimeout = nil
        self.activeResponseSessionID = nil
      }.get()
      try? await channel.close().get()
      return
    }
    nonisolated(unsafe) let sendableContext = context
    try? await eventLoop.submit {
      self.responseTimeout?.cancel()
      self.responseTimeout = nil
      self.activeResponseSessionID = nil
      self.releaseRequest()
      guard sendableContext.channel.isActive else { return }
      self.inputState = .waiting
      self.responseTask = nil
      self.scheduleHeaderTimeout(context: sendableContext)
    }.get()
  }

  private func makeRequest(_ state: RequestState) -> MCP.HTTPRequest {
    var headers: [String: String] = [:]
    for (name, value) in state.head.headers {
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

  private func isExactRoute(_ target: String) -> Bool {
    let candidate = Array(target.utf8)
    guard !candidate.contains(37), !candidate.contains(63), !candidate.contains(35) else {
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
      self.reject(status: .requestTimeout, context: sendableContext)
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
    guard requestAdmitted else { return }
    requestAdmitted = false
    admission.releaseRequest()
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

private actor MCPHTTPWritability {
  private var isWritable = true
  private var isOpen = true
  private var waiters: [CheckedContinuation<Void, any Error>] = []

  func update(isWritable: Bool, isOpen: Bool) {
    self.isWritable = isWritable
    self.isOpen = isOpen
    guard isWritable || !isOpen else { return }
    let pending = waiters
    waiters.removeAll(keepingCapacity: true)
    for waiter in pending {
      if isOpen {
        waiter.resume()
      } else {
        waiter.resume(throwing: MCPHTTPWriteError.channelClosed)
      }
    }
  }

  func waitUntilWritable() async throws {
    if !isOpen { throw MCPHTTPWriteError.channelClosed }
    if isWritable { return }
    try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
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
