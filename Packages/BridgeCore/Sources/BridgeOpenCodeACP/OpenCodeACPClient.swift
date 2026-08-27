import BridgeACP
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
  public let configOptions: [OpenCodeACPConfigOption]

  public init(id: String, configOptions: [OpenCodeACPConfigOption] = []) {
    self.id = id
    self.configOptions = configOptions
  }
}

public struct OpenCodeACPConfigOption: Equatable, Sendable {
  public let id: String
  public let currentValue: String?
  public let values: [OpenCodeACPConfigValue]

  public init(id: String, currentValue: String?, values: [OpenCodeACPConfigValue]) {
    self.id = id
    self.currentValue = currentValue
    self.values = values
  }
}

public struct OpenCodeACPConfigValue: Equatable, Sendable {
  public let value: String
  public let name: String

  public init(value: String, name: String) {
    self.value = value
    self.name = name
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
  private let requestBroker: BridgeACP.ACPRequestBroker
  private let clientInfo: OpenCodeACPClientInfo
  private let eventContinuation: AsyncStream<OpenCodeACPClientEventEnvelope>.Continuation
  private var readerTask: Task<Void, Never>?
  private var nextEventSequence: Int64 = 0
  private var pendingPermissions: [String: OpenCodeACPPermissionRequest] = [:]
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
    requestBroker = BridgeACP.ACPRequestBroker(
      transport: transport,
      requestTimeout: requestTimeout
    )
    self.clientInfo = clientInfo
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

  public func loadSession(id: String, cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/load",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value, fallbackID: id)
    guard session.id == id else { throw OpenCodeACPError.sessionMismatch }
    try bindSession(session.id)
    return session
  }

  public func resumeSession(id: String, cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/resume",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value, fallbackID: id)
    guard session.id == id else { throw OpenCodeACPError.sessionMismatch }
    try bindSession(session.id)
    return session
  }

  public func setSessionConfigOption(
    sessionID: String,
    configID: String,
    value: String
  ) async throws -> [OpenCodeACPConfigOption] {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    try validateIdentifier(configID)
    guard !value.isEmpty, value.utf8.count <= 256,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest("session.config.value")
    }
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/set_config_option",
      params: .object([
        "sessionId": .string(sessionID),
        "configId": .string(configID),
        "value": .string(value),
      ])
    )
    return try Self.parseConfigOptions(response.value["configOptions"])
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

    // ACP session/prompt resolves only when the whole turn finishes, so it
    // runs under the long lifetime budget instead of the per-RPC timeout.
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
      ]),
      timeout: .seconds(24 * 60 * 60)
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

  public func resolvePermission(
    approvalID: String,
    optionID: String
  ) async throws {
    try requireInitialized()
    try validateIdentifier(approvalID)
    try validateIdentifier(optionID)
    guard let request = pendingPermissions[approvalID] else {
      throw AgentRuntimeError.approvalUnavailable(approvalID)
    }
    guard request.options.contains(where: { $0.id == optionID }) else {
      throw AgentRuntimeError.approvalUnavailable(optionID)
    }
    try requireSession(request.sessionID)
    pendingPermissions.removeValue(forKey: approvalID)
    do {
      try await send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: optionID)
        )
      )
    } catch {
      await failConnection(error)
      throw error
    }
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
    requestBroker.failAll(with: OpenCodeACPError.transportClosed)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
    await requestBroker.close()
  }

  private func request(
    method: String,
    params: ACPJSONValue,
    timeout override: Duration? = nil
  ) async throws -> ACPClientResponse {
    guard started, !closed else { throw OpenCodeACPError.transportClosed }
    do {
      let response = try await requestBroker.request(
        method: method,
        params: params,
        timeout: override
      )
      return ACPClientResponse(
        value: response.value,
        eventSequenceBarrier: response.eventSequenceBarrier
      )
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  private func send(_ message: ACPWireMessage) async throws {
    guard !closed else { throw OpenCodeACPError.transportClosed }
    do {
      try await requestBroker.send(message)
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  private func receive(_ frame: Data) async {
    let message: ACPWireMessage
    do {
      message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    } catch {
      await failConnection(OpenCodeACPError.invalidMessage)
      return
    }
    do {
      switch try BridgeACP.ACPMessageDispatcher.dispatch(message) {
      case .serverRequest(let id, let method, let params):
        await handleServerRequest(id: id, method: method, params: params)
      case .response(let id, let result, let error):
        requestBroker.resolve(
          id: id,
          result: result,
          error: error,
          eventSequenceBarrier: nextEventSequence
        )
      case .notification(let method, let params):
        yield(.notification(OpenCodeACPNotification(method: method, params: params)))
      }
    } catch {
      await failConnection(Self.compatibilityError(for: error))
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
      let request = try Self.parsePermissionRequest(
        approvalID: nextApprovalID(),
        id: id,
        params: params
      )
      try requireSession(request.sessionID)
      guard pendingPermissions[request.approvalID] == nil else {
        throw AgentRuntimeError.approvalUnavailable(request.approvalID)
      }
      pendingPermissions[request.approvalID] = request
      yield(.permissionRequested(request))
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

  private func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    requestBroker.failAll(with: error ?? OpenCodeACPError.transportClosed)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
  }

  private func failConnection(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    requestBroker.failAll(with: error)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
    await requestBroker.close()
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

  private static func parseSession(
    _ value: ACPJSONValue,
    fallbackID: String? = nil
  ) throws -> OpenCodeACPSession {
    guard let id = value["sessionId"]?.stringValue ?? fallbackID else {
      throw OpenCodeACPError.malformedResponse
    }
    try validateIdentifier(id)
    let options = try parseConfigOptions(value["configOptions"])
    return OpenCodeACPSession(id: id, configOptions: options)
  }

  private static func parseConfigOptions(_ value: ACPJSONValue?) throws
    -> [OpenCodeACPConfigOption]
  {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue, rawOptions.count <= 64 else {
      throw OpenCodeACPError.malformedResponse
    }
    var seen = Set<String>()
    return try rawOptions.map { raw in
      guard let object = raw.objectValue,
        let id = object["id"]?.stringValue,
        seen.insert(id).inserted
      else {
        throw OpenCodeACPError.malformedResponse
      }
      try validateIdentifier(id)
      let currentValue = object["currentValue"]?.stringValue
      if let currentValue { try validateConfigText(currentValue, maximumBytes: 256) }
      let rawValues = object["options"]?.arrayValue ?? []
      guard rawValues.count <= 512 else { throw OpenCodeACPError.malformedResponse }
      var seenValues = Set<String>()
      let values = try rawValues.map { rawValue -> OpenCodeACPConfigValue in
        guard let entry = rawValue.objectValue,
          let value = entry["value"]?.stringValue,
          let name = entry["name"]?.stringValue,
          seenValues.insert(value).inserted
        else {
          throw OpenCodeACPError.malformedResponse
        }
        try validateConfigText(value, maximumBytes: 256)
        try validateConfigText(name, maximumBytes: 512)
        return OpenCodeACPConfigValue(value: value, name: name)
      }
      return OpenCodeACPConfigOption(id: id, currentValue: currentValue, values: values)
    }
  }

  private static func validateConfigText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw OpenCodeACPError.malformedResponse
    }
  }

  private func nextApprovalID() throws -> String {
    for _ in 0..<8 {
      let value = "opencode-\(UUID().uuidString.lowercased())"
      if pendingPermissions[value] == nil { return value }
    }
    throw AgentRuntimeError.approvalUnavailable("id")
  }

  private static func parsePermissionRequest(
    approvalID: String,
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
    guard !title.isEmpty, title.utf8.count <= 1_024,
      !title.contains("\0")
    else {
      throw OpenCodeACPError.invalidMessage
    }
    return OpenCodeACPPermissionRequest(
      approvalID: approvalID,
      requestID: id,
      sessionID: sessionID,
      toolCallID: toolCallID,
      title: title,
      kind: toolCall["kind"]?.stringValue,
      rawInput: toolCall["rawInput"],
      options: options
    )
  }

  private static func permissionSelection(optionID: String) -> ACPJSONValue {
    return .object([
      "outcome": .object([
        "outcome": .string("selected"),
        "optionId": .string(optionID),
      ])
    ])
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

  private static func compatibilityError(for error: any Error) -> OpenCodeACPError {
    if let error = error as? OpenCodeACPError { return error }
    if let error = error as? BridgeACP.ACPError {
      switch error {
      case .invalidMessage: return .invalidMessage
      case .malformedResponse: return .malformedResponse
      case .remote(let code, let message): return .remote(code: code, message: message)
      case .requestTimedOut: return .requestTimedOut
      case .transportClosed: return .transportClosed
      case .processExited(let code): return .processExited(code)
      case .oversizedFrame: return .oversizedFrame
      }
    }
    return .transportClosed
  }
}
