import BridgeAgentCore
import Foundation

public struct OpenCodeACPClientInfo: Equatable, Sendable {
  public let name: String
  public let title: String
  public let version: String

  public init(name: String, title: String, version: String) {
    self.name = name
    self.title = title
    self.version = version
  }
}

public struct OpenCodeACPInitialization: Equatable, Sendable {
  public let protocolVersion: Int
  public let agentName: String?
  public let agentTitle: String?
  public let agentVersion: String?
  public let advertisedCapabilities: Set<AgentCapability>
  public let supportsLoadSession: Bool
  public let supportsResumeSession: Bool
  public let supportsCloseSession: Bool

  public init(
    protocolVersion: Int,
    agentName: String?,
    agentTitle: String?,
    agentVersion: String?,
    advertisedCapabilities: Set<AgentCapability>,
    supportsLoadSession: Bool,
    supportsResumeSession: Bool,
    supportsCloseSession: Bool
  ) {
    self.protocolVersion = protocolVersion
    self.agentName = agentName
    self.agentTitle = agentTitle
    self.agentVersion = agentVersion
    self.advertisedCapabilities = advertisedCapabilities
    self.supportsLoadSession = supportsLoadSession
    self.supportsResumeSession = supportsResumeSession
    self.supportsCloseSession = supportsCloseSession
  }
}

public struct OpenCodeACPSession: Equatable, Sendable {
  public let id: String

  public init(id: String) {
    self.id = id
  }
}

public struct OpenCodeACPPromptResult: Equatable, Sendable {
  public let stopReason: String
  public let eventSequenceBarrier: Int64

  public init(stopReason: String, eventSequenceBarrier: Int64) {
    self.stopReason = stopReason
    self.eventSequenceBarrier = eventSequenceBarrier
  }
}

private struct ACPClientResponse: Sendable {
  let value: ACPJSONValue
  let eventSequenceBarrier: Int64
}

public actor OpenCodeACPClient {
  public nonisolated let events: AsyncStream<OpenCodeACPClientEventEnvelope>

  private let transport: any OpenCodeACPTransport
  private let clientInfo: OpenCodeACPClientInfo
  private let requestTimeout: Duration
  private let eventContinuation: AsyncStream<OpenCodeACPClientEventEnvelope>.Continuation
  private var readerTask: Task<Void, Never>?
  private var nextRequestID: Int64 = 1
  private var pending: [ACPRequestID: CheckedContinuation<ACPClientResponse, any Error>] = [:]
  private var nextEventSequence: Int64 = 0
  private var timeoutTasks: [ACPRequestID: Task<Void, Never>] = [:]
  private var started = false
  private var closed = false
  private var initializationStorage: OpenCodeACPInitialization?
  private var initializationTask: Task<OpenCodeACPInitialization, any Error>?
  private var activeSessionID: String?
  private var sessionOperationInFlight = false

  public init(
    transport: any OpenCodeACPTransport,
    clientInfo: OpenCodeACPClientInfo,
    requestTimeout: Duration = .seconds(30),
    eventBufferLimit: Int = 256
  ) {
    let pair = AsyncStream.makeStream(
      of: OpenCodeACPClientEventEnvelope.self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.transport = transport
    self.clientInfo = clientInfo
    self.requestTimeout = requestTimeout
    events = pair.stream
    eventContinuation = pair.continuation
  }

  public var initialization: OpenCodeACPInitialization? {
    initializationStorage
  }

  public var eventSequence: Int64 {
    nextEventSequence
  }

  public func start() {
    guard !started, !closed else { return }
    started = true
    let source = transport.incoming
    readerTask = Task { [weak self] in
      do {
        for try await frame in source {
          guard let self else { return }
          await self.receive(frame)
        }
        await self?.transportEnded(error: nil)
      } catch {
        await self?.transportEnded(error: error)
      }
    }
  }

  public func initialize() async throws -> OpenCodeACPInitialization {
    start()
    if let initializationStorage { return initializationStorage }
    if let initializationTask {
      do {
        let initialization = try await initializationTask.value
        initializationStorage = initialization
        self.initializationTask = nil
        return initialization
      } catch {
        self.initializationTask = nil
        throw error
      }
    }

    let task = Task { [weak self] () throws -> OpenCodeACPInitialization in
      guard let self else { throw OpenCodeACPError.transportClosed }
      return try await self.performInitialization()
    }
    initializationTask = task
    do {
      let initialization = try await task.value
      initializationStorage = initialization
      initializationTask = nil
      return initialization
    } catch {
      initializationTask = nil
      throw error
    }
  }

  private func performInitialization() async throws -> OpenCodeACPInitialization {
    let response = try await request(
      method: "initialize",
      params: .object([
        "protocolVersion": .integer(1),
        "clientCapabilities": .object([:]),
        "clientInfo": .object([
          "name": .string(clientInfo.name),
          "title": .string(clientInfo.title),
          "version": .string(clientInfo.version),
        ]),
      ])
    )
    let initialization = try Self.parseInitialization(response.value)
    guard initialization.protocolVersion == 1 else {
      throw OpenCodeACPError.unsupportedProtocol(initialization.protocolVersion)
    }
    return initialization
  }

  public func newSession(cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateAbsolutePath(cwd)
    guard activeSessionID == nil else { throw OpenCodeACPError.sessionMismatch }
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/new",
      params: .object([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value)
    try bindSession(session.id)
    return session
  }

  public func loadSession(id: String, cwd: String) async throws {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    _ = try await request(
      method: "session/load",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    try bindSession(id)
  }

  public func resumeSession(id: String, cwd: String) async throws {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    _ = try await request(
      method: "session/resume",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    try bindSession(id)
  }

  public func prompt(sessionID: String, text: String) async throws -> OpenCodeACPPromptResult {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32 * 1_024,
      !text.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("prompt.text")
    }
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/prompt",
      params: .object([
        "sessionId": .string(sessionID),
        "prompt": .array([
          .object([
            "type": .string("text"),
            "text": .string(text),
          ])
        ]),
      ])
    )
    guard let stopReason = response.value["stopReason"]?.stringValue,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      !stopReason.contains("\0")
    else {
      throw OpenCodeACPError.malformedResponse
    }
    return OpenCodeACPPromptResult(
      stopReason: stopReason,
      eventSequenceBarrier: response.eventSequenceBarrier
    )
  }

  public func cancel(sessionID: String) async throws {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    try await send(
      ACPWireMessage(
        method: "session/cancel",
        params: .object(["sessionId": .string(sessionID)])
      )
    )
  }

  public func closeSession(id: String) async throws {
    try requireInitialized()
    try validateIdentifier(id)
    try requireSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    _ = try await request(
      method: "session/close",
      params: .object(["sessionId": .string(id)])
    )
    activeSessionID = nil
  }

  public func shutdown() async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    failPending(with: OpenCodeACPError.transportClosed)
    eventContinuation.finish()
    await transport.close()
  }

  private func request(method: String, params: ACPJSONValue) async throws -> ACPClientResponse {
    guard started, !closed else { throw OpenCodeACPError.transportClosed }
    guard nextRequestID > 0, nextRequestID < Int64.max else {
      throw OpenCodeACPError.transportClosed
    }
    let id = ACPRequestID.integer(nextRequestID)
    nextRequestID += 1
    let message = ACPWireMessage(id: id, method: method, params: params)
    let data = try JSONEncoder().encode(message)
    let timeout = requestTimeout

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timeoutTasks[id] = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          await self?.timeout(id: id)
        }
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.transport.send(data)
          } catch {
            await self.fail(id: id, error: error)
          }
        }
      }
    } onCancel: {
      Task { [weak self] in await self?.fail(id: id, error: CancellationError()) }
    }
  }

  private func send(_ message: ACPWireMessage) async throws {
    guard !closed else { throw OpenCodeACPError.transportClosed }
    try await transport.send(JSONEncoder().encode(message))
  }

  private func receive(_ frame: Data) async {
    let message: ACPWireMessage
    do {
      message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    } catch {
      await failConnection(OpenCodeACPError.invalidMessage)
      return
    }
    guard message.jsonrpc == "2.0" else {
      await failConnection(OpenCodeACPError.invalidMessage)
      return
    }

    if let id = message.id, let method = message.method {
      guard message.result == nil, message.error == nil,
        Self.isValidRequestID(id), Self.isValidMethod(method)
      else {
        await failConnection(OpenCodeACPError.invalidMessage)
        return
      }
      await handleServerRequest(id: id, method: method, params: message.params)
      return
    }
    if let id = message.id {
      guard message.method == nil, Self.isValidRequestID(id),
        (message.result != nil) != (message.error != nil)
      else {
        await failConnection(OpenCodeACPError.invalidMessage)
        return
      }
      handleResponse(id: id, result: message.result, error: message.error)
      return
    }
    if let method = message.method {
      guard message.result == nil, message.error == nil, Self.isValidMethod(method) else {
        await failConnection(OpenCodeACPError.invalidMessage)
        return
      }
      yield(.notification(OpenCodeACPNotification(method: method, params: message.params)))
      return
    }
    await failConnection(OpenCodeACPError.invalidMessage)
  }

  private func handleResponse(
    id: ACPRequestID,
    result: ACPJSONValue?,
    error: ACPWireError?
  ) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    if let error {
      guard error.message.utf8.count <= 4 * 1_024, !error.message.contains("\0") else {
        continuation.resume(throwing: OpenCodeACPError.malformedResponse)
        return
      }
      continuation.resume(
        throwing: OpenCodeACPError.remote(code: error.code, message: error.message))
    } else if let result {
      continuation.resume(
        returning: ACPClientResponse(
          value: result,
          eventSequenceBarrier: nextEventSequence
        )
      )
    } else {
      continuation.resume(throwing: OpenCodeACPError.malformedResponse)
    }
  }

  private func handleServerRequest(
    id: ACPRequestID,
    method: String,
    params: ACPJSONValue?
  ) async {
    guard method == "session/request_permission" else {
      try? await send(
        ACPWireMessage(
          id: id,
          error: ACPWireError(code: -32601, message: "Method not found")
        )
      )
      return
    }

    do {
      let request = try Self.parsePermissionRequest(id: id, params: params)
      try requireSession(request.sessionID)
      let rejection = Self.permissionRejection(options: request.options)
      try await send(ACPWireMessage(id: id, result: rejection))
      yield(.permissionDenied(request))
    } catch {
      try? await send(
        ACPWireMessage(
          id: id,
          error: ACPWireError(code: -32602, message: "Invalid permission request")
        )
      )
    }
  }

  private func yield(_ event: OpenCodeACPClientEvent) {
    let envelope = OpenCodeACPClientEventEnvelope(
      sequence: nextEventSequence,
      event: event
    )
    nextEventSequence += 1
    if case .dropped = eventContinuation.yield(envelope) {
      Task { [weak self] in await self?.failConnection(OpenCodeACPError.transportClosed) }
    }
  }

  private func timeout(id: ACPRequestID) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    continuation.resume(throwing: OpenCodeACPError.requestTimedOut)
  }

  private func fail(id: ACPRequestID, error: any Error) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    continuation.resume(throwing: error)
  }

  private func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    failPending(with: error ?? OpenCodeACPError.transportClosed)
    eventContinuation.finish()
  }

  private func failConnection(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    failPending(with: error)
    eventContinuation.finish()
    await transport.close()
  }

  private func failPending(with error: any Error) {
    let continuations = Array(pending.values)
    pending.removeAll()
    for task in timeoutTasks.values { task.cancel() }
    timeoutTasks.removeAll()
    for continuation in continuations { continuation.resume(throwing: error) }
  }

  private func requireInitialized() throws {
    guard initializationStorage != nil, !closed else {
      throw OpenCodeACPError.notInitialized
    }
  }

  private func beginSessionOperation() throws {
    guard !sessionOperationInFlight else {
      throw OpenCodeACPError.operationInProgress
    }
    sessionOperationInFlight = true
  }

  private func endSessionOperation() {
    sessionOperationInFlight = false
  }

  private func ensureCanBindSession(_ sessionID: String) throws {
    guard activeSessionID == nil || activeSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }

  private func bindSession(_ sessionID: String) throws {
    try ensureCanBindSession(sessionID)
    activeSessionID = sessionID
  }

  private func requireSession(_ sessionID: String) throws {
    guard activeSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }

  private static func parseInitialization(_ value: ACPJSONValue) throws
    -> OpenCodeACPInitialization
  {
    guard let object = value.objectValue,
      let protocolVersion = object["protocolVersion"]?.intValue
    else {
      throw OpenCodeACPError.malformedResponse
    }
    let capabilities = object["agentCapabilities"]?.objectValue ?? [:]
    let sessionCapabilities = capabilities["sessionCapabilities"]?.objectValue ?? [:]
    let load = capabilities["loadSession"]?.boolValue == true
    let resume = sessionCapabilities["resume"] != nil
    let close = sessionCapabilities["close"] != nil
    let info = object["agentInfo"]?.objectValue

    var advertised: Set<AgentCapability> = [
      .sessionCreate,
      .interrupt,
      .textDelta,
      .toolLifecycle,
    ]
    if load || resume { advertised.insert(.sessionContinue) }

    return OpenCodeACPInitialization(
      protocolVersion: protocolVersion,
      agentName: info?["name"]?.stringValue,
      agentTitle: info?["title"]?.stringValue,
      agentVersion: info?["version"]?.stringValue,
      advertisedCapabilities: advertised,
      supportsLoadSession: load,
      supportsResumeSession: resume,
      supportsCloseSession: close
    )
  }

  private static func parseSession(_ value: ACPJSONValue) throws -> OpenCodeACPSession {
    guard let id = value["sessionId"]?.stringValue else {
      throw OpenCodeACPError.malformedResponse
    }
    try validateIdentifier(id)
    return OpenCodeACPSession(id: id)
  }

  private static func parsePermissionRequest(
    id: ACPRequestID,
    params: ACPJSONValue?
  ) throws -> OpenCodeACPPermissionRequest {
    guard let object = params?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let toolCall = object["toolCall"]?.objectValue,
      let toolCallID = toolCall["toolCallId"]?.stringValue,
      let rawOptions = object["options"]?.arrayValue
    else {
      throw OpenCodeACPError.invalidMessage
    }
    try validateIdentifier(sessionID)
    try validateIdentifier(toolCallID)
    guard !rawOptions.isEmpty, rawOptions.count <= 16 else {
      throw OpenCodeACPError.invalidMessage
    }
    let options = try rawOptions.map { value -> AgentApprovalOption in
      guard let option = value.objectValue,
        let optionID = option["optionId"]?.stringValue,
        let name = option["name"]?.stringValue,
        let kind = option["kind"]?.stringValue
      else {
        throw OpenCodeACPError.invalidMessage
      }
      return try AgentApprovalOption(id: optionID, name: name, kind: kind)
    }
    guard !options.isEmpty else { throw OpenCodeACPError.invalidMessage }
    let title = toolCall["title"]?.stringValue ?? "OpenCode tool request"
    return OpenCodeACPPermissionRequest(
      requestID: id,
      sessionID: sessionID,
      toolCallID: toolCallID,
      title: title,
      kind: toolCall["kind"]?.stringValue,
      rawInput: toolCall["rawInput"],
      options: options
    )
  }

  private static func permissionRejection(options: [AgentApprovalOption]) -> ACPJSONValue {
    let reject =
      options.first(where: { $0.kind == "reject_once" })
      ?? options.first(where: { $0.kind == "reject_always" })
    if let reject {
      return .object([
        "outcome": .object([
          "outcome": .string("selected"),
          "optionId": .string(reject.id),
        ])
      ])
    }
    return .object([
      "outcome": .object(["outcome": .string("cancelled")])
    ])
  }

  private static func isValidRequestID(_ id: ACPRequestID) -> Bool {
    switch id {
    case .integer:
      true
    case .string(let value):
      !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
  }

  private static func isValidMethod(_ method: String) -> Bool {
    !method.isEmpty && method.utf8.count <= 256 && !method.contains("\0")
  }

  private static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("identifier")
    }
  }

  private func validateIdentifier(_ value: String) throws {
    try Self.validateIdentifier(value)
  }

  private func validateAbsolutePath(_ value: String) throws {
    guard value.hasPrefix("/"), value.utf8.count <= 16 * 1_024, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("path")
    }
  }
}
