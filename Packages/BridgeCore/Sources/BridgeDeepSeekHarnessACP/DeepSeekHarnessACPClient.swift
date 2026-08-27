import BridgeACP
import BridgeAgentCore
import Foundation

public actor DeepSeekHarnessACPClient {
  public nonisolated let events: AsyncStream<DeepSeekHarnessACPClientEventEnvelope>

  private let broker: ACPRequestBroker
  private let transport: any ACPTransport
  private let clientInfo: DeepSeekHarnessACPClientInfo
  private let requestTimeout: Duration
  private let eventContinuation: AsyncStream<DeepSeekHarnessACPClientEventEnvelope>.Continuation
  private var readerTask: Task<Void, Never>?
  private var initializationTask: Task<DeepSeekHarnessACPInitialization, any Error>?
  private var initializationStorage: DeepSeekHarnessACPInitialization?
  private var activeSessionID: String?
  private var pendingPermissions: [String: DeepSeekHarnessACPPermissionRequest] = [:]
  private var nextEventSequence: Int64 = 0
  private var started = false
  private var closed = false
  private var sessionOperationInFlight = false

  public init(
    transport: any ACPTransport,
    clientInfo: DeepSeekHarnessACPClientInfo,
    requestTimeout: Duration = DeepSeekHarnessACPConstants.requestTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer
  ) {
    let pair = AsyncStream.makeStream(
      of: DeepSeekHarnessACPClientEventEnvelope.self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.transport = transport
    broker = ACPRequestBroker(transport: transport, requestTimeout: requestTimeout)
    self.clientInfo = clientInfo
    self.requestTimeout = requestTimeout
    events = pair.stream
    eventContinuation = pair.continuation
  }

  public var initialization: DeepSeekHarnessACPInitialization? {
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

  public func initialize() async throws -> DeepSeekHarnessACPInitialization {
    start()
    if let initializationStorage { return initializationStorage }
    if let initializationTask {
      do {
        let value = try await initializationTask.value
        initializationStorage = value
        self.initializationTask = nil
        return value
      } catch {
        self.initializationTask = nil
        throw error
      }
    }
    let task = Task { [weak self] () throws -> DeepSeekHarnessACPInitialization in
      guard let self else { throw DeepSeekHarnessACPError.transportClosed }
      return try await self.performInitialization()
    }
    initializationTask = task
    do {
      let value = try await task.value
      initializationStorage = value
      initializationTask = nil
      return value
    } catch {
      initializationTask = nil
      throw error
    }
  }

  public func newSession(cwd: String) async throws -> DeepSeekHarnessACPSession {
    try requireInitialized()
    try validateAbsolutePath(cwd, field: "session.cwd")
    guard activeSessionID == nil else { throw DeepSeekHarnessACPError.sessionMismatch }
    try beginSessionOperation()
    defer { endSessionOperation() }
    let response = try await request(
      method: "session/new",
      params: .object([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
        "additionalDirectories": .array([]),
      ])
    )
    guard let sessionID = response.value["sessionId"]?.stringValue else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    try validateIdentifier(sessionID, field: "session.id")
    let configOptions = try Self.parseConfigOptions(response.value["configOptions"])
    activeSessionID = sessionID
    return DeepSeekHarnessACPSession(id: sessionID, configOptions: configOptions)
  }

  public func setSessionConfigOption(
    sessionID: String,
    configID: String,
    value: String
  ) async throws -> [DeepSeekHarnessACPConfigOption] {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
    try validateIdentifier(configID, field: "session.configID")
    try validateIdentifier(value, field: "session.configValue")
    try requireSession(sessionID)
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

  public func prompt(sessionID: String, text: String) async throws -> DeepSeekHarnessACPPromptResult
  {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
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
      ]),
      timeout: DeepSeekHarnessACPConstants.maximumProcessLifetime
    )
    guard let stopReason = response.value["stopReason"]?.stringValue,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      !stopReason.contains("\0"),
      stopReason.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    return DeepSeekHarnessACPPromptResult(
      stopReason: stopReason,
      eventSequenceBarrier: response.eventSequenceBarrier
    )
  }

  public func cancel(sessionID: String) async throws {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
    try requireSession(sessionID)
    try await broker.send(
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
    try validateIdentifier(approvalID, field: "approval.id")
    try validateIdentifier(optionID, field: "approval.optionID")
    guard let request = pendingPermissions[approvalID] else {
      throw AgentRuntimeError.approvalUnavailable(approvalID)
    }
    try requireSession(request.sessionID)
    guard let option = request.options.first(where: { $0.id == optionID }),
      Self.isOneShotPermissionKind(option.kind)
    else {
      throw AgentRuntimeError.approvalUnavailable(optionID)
    }
    pendingPermissions.removeValue(forKey: approvalID)
    do {
      try await broker.send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: optionID)
        )
      )
    } catch {
      let mapped = Self.map(error)
      await failConnection(mapped)
      throw mapped
    }
  }

  public func shutdown() async {
    guard !closed else { return }
    closed = true
    let pending = Array(pendingPermissions.values)
    pendingPermissions.removeAll()
    for request in pending {
      try? await broker.send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: Self.rejectOptionID(in: request.options))
        )
      )
    }
    if let activeSessionID, initializationStorage != nil {
      try? await broker.send(
        ACPWireMessage(
          method: "session/cancel",
          params: .object(["sessionId": .string(activeSessionID)])
        )
      )
    }
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    eventContinuation.finish()
    await broker.close()
  }

  private func performInitialization() async throws -> DeepSeekHarnessACPInitialization {
    let response = try await request(
      method: "initialize",
      params: .object([
        "protocolVersion": .integer(Int64(DeepSeekHarnessACPConstants.acpProtocolVersion)),
        "clientCapabilities": .object([:]),
        "clientInfo": .object([
          "name": .string(clientInfo.name),
          "title": .string(clientInfo.title),
          "version": .string(clientInfo.version),
        ]),
      ])
    )
    guard let object = response.value.objectValue,
      let protocolVersion = object["protocolVersion"]?.intValue
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    let agentInfo: [String: ACPJSONValue]?
    if let value = object["agentInfo"] {
      guard let decoded = value.objectValue,
        decoded["name"]?.stringValue != nil,
        decoded["version"]?.stringValue != nil
      else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      agentInfo = decoded
    } else {
      agentInfo = nil
    }
    let initialization = DeepSeekHarnessACPInitialization(
      protocolVersion: protocolVersion,
      agentName: agentInfo?["name"]?.stringValue,
      agentTitle: agentInfo?["title"]?.stringValue,
      agentVersion: agentInfo?["version"]?.stringValue
    )
    guard initialization.protocolVersion == DeepSeekHarnessACPConstants.acpProtocolVersion else {
      throw DeepSeekHarnessACPError.unsupportedProtocol(initialization.protocolVersion)
    }
    return initialization
  }

  private func request(
    method: String,
    params: ACPJSONValue,
    timeout: Duration? = nil
  ) async throws -> ACPRequestResponse {
    guard started, !closed else { throw DeepSeekHarnessACPError.transportClosed }
    do {
      return try await broker.request(method: method, params: params, timeout: timeout)
    } catch {
      throw Self.map(error)
    }
  }

  private func receive(_ frame: Data) async {
    guard !closed else { return }
    let message: ACPWireMessage
    do {
      message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    } catch {
      await failConnection(DeepSeekHarnessACPError.invalidMessage)
      return
    }
    do {
      switch try ACPMessageDispatcher.dispatch(message) {
      case .response(let id, let result, let error):
        let resolved = broker.resolve(
          id: id,
          result: result,
          error: error,
          eventSequenceBarrier: nextEventSequence
        )
        guard resolved else {
          await failConnection(DeepSeekHarnessACPError.malformedResponse)
          return
        }
      case .notification(let method, let params):
        try handleNotification(method: method, params: params)
      case .serverRequest(let id, let method, let params):
        try await handleServerRequest(id: id, method: method, params: params)
      }
    } catch {
      await failConnection(Self.map(error))
    }
  }

  private func handleNotification(method: String, params: ACPJSONValue?) throws {
    guard method == "session/update",
      let object = params?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let update = object["update"]?.objectValue,
      update["sessionUpdate"]?.stringValue == "agent_message_chunk",
      let content = update["content"]?.objectValue,
      content["type"]?.stringValue == "text",
      let text = content["text"]?.stringValue
    else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    try requireSession(sessionID)
    guard text.utf8.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      !text.contains("\0")
    else {
      throw DeepSeekHarnessACPError.oversizedFrame
    }
    guard !text.isEmpty else { return }
    yield(.textDelta(sessionID: sessionID, text: text))
  }

  private func handleServerRequest(
    id: ACPRequestID,
    method: String,
    params: ACPJSONValue?
  ) async throws {
    guard method == "session/request_permission" else {
      throw DeepSeekHarnessACPError.invalidMessage
    }
    guard pendingPermissions.count < DeepSeekHarnessACPConstants.maximumPendingPermissions else {
      throw AgentRuntimeError.approvalUnavailable("capacity")
    }
    let permission = try Self.parsePermission(
      params,
      requestID: id,
      approvalID: try nextApprovalID()
    )
    try requireSession(permission.sessionID)
    guard pendingPermissions[permission.approvalID] == nil else {
      throw AgentRuntimeError.approvalUnavailable(permission.approvalID)
    }
    pendingPermissions[permission.approvalID] = permission
    yield(.permissionRequested(permission))
  }

  private func transportEnded(error: (any Error)?) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    broker.failAll(with: Self.map(error ?? DeepSeekHarnessACPError.transportClosed))
    eventContinuation.finish()
  }

  private func failConnection(_ error: any Error) async {
    guard !closed else { return }
    closed = true
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    pendingPermissions.removeAll()
    readerTask?.cancel()
    readerTask = nil
    broker.failAll(with: error)
    eventContinuation.finish()
    await transport.close()
  }

  private func yield(_ event: DeepSeekHarnessACPClientEvent) {
    let envelope = DeepSeekHarnessACPClientEventEnvelope(
      sequence: nextEventSequence,
      event: event
    )
    nextEventSequence += 1
    if case .dropped = eventContinuation.yield(envelope) {
      Task { [weak self] in
        await self?.failConnection(DeepSeekHarnessACPError.transportClosed)
      }
    }
  }

  private func requireInitialized() throws {
    if closed { throw DeepSeekHarnessACPError.transportClosed }
    guard initializationStorage != nil else {
      throw DeepSeekHarnessACPError.notInitialized
    }
  }

  private func beginSessionOperation() throws {
    guard !sessionOperationInFlight else {
      throw DeepSeekHarnessACPError.operationInProgress
    }
    sessionOperationInFlight = true
  }

  private func endSessionOperation() {
    sessionOperationInFlight = false
  }

  private func requireSession(_ sessionID: String) throws {
    guard activeSessionID == sessionID else {
      throw DeepSeekHarnessACPError.sessionMismatch
    }
  }

  private func nextApprovalID() throws -> String {
    for _ in 0..<8 {
      let value = "deepseek-\(UUID().uuidString.lowercased())"
      if pendingPermissions[value] == nil { return value }
    }
    throw AgentRuntimeError.approvalUnavailable("id")
  }

  private static func parsePermission(
    _ value: ACPJSONValue?,
    requestID: ACPRequestID,
    approvalID: String
  ) throws -> DeepSeekHarnessACPPermissionRequest {
    guard let object = value?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let toolCall = object["toolCall"]?.objectValue,
      let toolCallID = toolCall["toolCallId"]?.stringValue,
      let values = object["options"]?.arrayValue,
      !values.isEmpty,
      values.count <= 16
    else {
      throw DeepSeekHarnessACPError.malformedPermission
    }
    try validateIdentifier(sessionID, field: "permission.sessionID")
    try validateIdentifier(toolCallID, field: "permission.toolCallID")
    let title = toolCall["title"]?.stringValue ?? "DeepSeek Harness permission request"
    guard !title.isEmpty, title.utf8.count <= 1_024, !title.contains("\0"),
      title.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedPermission
    }
    if let kind = toolCall["kind"]?.stringValue {
      try validateIdentifier(kind, field: "permission.toolKind")
    }
    let options = try values.map { value -> AgentApprovalOption in
      guard let option = value.objectValue,
        let optionID = option["optionId"]?.stringValue,
        let name = option["name"]?.stringValue,
        let kind = option["kind"]?.stringValue,
        isOneShotPermissionKind(kind)
      else {
        throw DeepSeekHarnessACPError.malformedPermission
      }
      do {
        return try AgentApprovalOption(id: optionID, name: name, kind: kind)
      } catch {
        throw DeepSeekHarnessACPError.malformedPermission
      }
    }
    guard Set(options.map(\.id)).count == options.count,
      options.contains(where: { isRejectOnce($0.kind) })
    else {
      throw DeepSeekHarnessACPError.missingRejectOnce
    }
    let rawInput = toolCall["rawInput"]
    if let rawInput {
      guard let data = try? JSONEncoder().encode(rawInput),
        data.count <= DeepSeekHarnessACPConstants.maximumPermissionInputBytes
      else {
        throw DeepSeekHarnessACPError.malformedPermission
      }
    }
    return DeepSeekHarnessACPPermissionRequest(
      approvalID: approvalID,
      requestID: requestID,
      sessionID: sessionID,
      toolCallID: toolCallID,
      title: title,
      kind: toolCall["kind"]?.stringValue,
      rawInput: rawInput,
      options: options,
    )
  }

  private static func parseConfigOptions(_ value: ACPJSONValue?) throws
    -> [DeepSeekHarnessACPConfigOption]
  {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue, rawOptions.count <= 64 else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    var seen = Set<String>()
    return try rawOptions.map { raw in
      guard let object = raw.objectValue,
        let id = object["id"]?.stringValue,
        seen.insert(id).inserted
      else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      try validateConfigText(id, maximumBytes: 256)
      let category = object["category"]?.stringValue
      if let category { try validateConfigText(category, maximumBytes: 64) }
      let currentValue = object["currentValue"]?.stringValue
      if let currentValue { try validateConfigText(currentValue, maximumBytes: 256) }
      guard let rawValues = object["options"]?.arrayValue, rawValues.count <= 512 else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      var seenValues = Set<String>()
      let values = try rawValues.map { rawValue -> DeepSeekHarnessACPConfigValue in
        guard let entry = rawValue.objectValue,
          let value = entry["value"]?.stringValue,
          let name = entry["name"]?.stringValue,
          seenValues.insert(value).inserted
        else {
          throw DeepSeekHarnessACPError.malformedResponse
        }
        try validateConfigText(value, maximumBytes: 256)
        try validateConfigText(name, maximumBytes: 512)
        return DeepSeekHarnessACPConfigValue(value: value, name: name)
      }
      return DeepSeekHarnessACPConfigOption(
        id: id,
        category: category,
        currentValue: currentValue,
        values: values
      )
    }
  }

  private static func validateConfigText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
  }

  private static func isRejectOnce(_ value: String) -> Bool {
    value.replacingOccurrences(of: "-", with: "_").lowercased() == "reject_once"
  }

  private static func isOneShotPermissionKind(_ value: String) -> Bool {
    isAllowOnce(value) || isRejectOnce(value)
  }

  private static func isAllowOnce(_ value: String) -> Bool {
    value.replacingOccurrences(of: "-", with: "_").lowercased() == "allow_once"
  }

  private static func rejectOptionID(in options: [AgentApprovalOption]) -> String {
    options.first(where: { isRejectOnce($0.kind) })?.id ?? "reject-once"
  }

  private static func permissionSelection(optionID: String) -> ACPJSONValue {
    .object([
      "outcome": .object([
        "outcome": .string("selected"),
        "optionId": .string(optionID),
      ])
    ])
  }

  private static func validateAbsolutePath(_ value: String, field: String) throws {
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  private static func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  private func validateAbsolutePath(_ value: String, field: String) throws {
    try Self.validateAbsolutePath(value, field: field)
  }

  private func validateIdentifier(_ value: String, field: String) throws {
    try Self.validateIdentifier(value, field: field)
  }

  private static func map(_ error: any Error) -> any Error {
    if error is DeepSeekHarnessACPError || error is AgentRuntimeError { return error }
    guard let error = error as? ACPError else { return DeepSeekHarnessACPError.transportClosed }
    switch error {
    case .invalidMessage: return DeepSeekHarnessACPError.invalidMessage
    case .malformedResponse: return DeepSeekHarnessACPError.malformedResponse
    case .remote(let code, let message):
      return DeepSeekHarnessACPError.remote(code: code, message: message)
    case .requestTimedOut: return DeepSeekHarnessACPError.requestTimedOut
    case .transportClosed: return DeepSeekHarnessACPError.transportClosed
    case .processExited(let code): return DeepSeekHarnessACPError.processExited(code)
    case .oversizedFrame: return DeepSeekHarnessACPError.oversizedFrame
    }
  }
}
