import Foundation

public actor CodexAppServerClient {
  private enum Lifecycle: Equatable {
    case new
    case starting
    case ready
    case initializing
    case initialized
    case stopped

    var isRunning: Bool {
      switch self {
      case .ready, .initializing, .initialized:
        true
      case .new, .starting, .stopped:
        false
      }
    }
  }

  package nonisolated let events: AsyncStream<AppServerEvent>

  private let process: AppServerProcess
  private let dispatcher: RPCDispatcher
  private let defaultTimeoutNanoseconds: UInt64
  private var nextRequestID: Int64 = 1
  private var lifecycle = Lifecycle.new

  public init(
    configuration: AppServerConfiguration = .codex(),
    defaultTimeoutNanoseconds: UInt64 = 10_000_000_000,
    eventBufferLimit: Int = 256
  ) {
    let dispatcher = RPCDispatcher(eventBufferLimit: eventBufferLimit)
    self.dispatcher = dispatcher
    process = AppServerProcess(configuration: configuration)
    events = dispatcher.events
    self.defaultTimeoutNanoseconds = defaultTimeoutNanoseconds
  }

  public func start() async throws {
    guard lifecycle == .new else { throw CodexRPCError.alreadyStarted }
    lifecycle = .starting
    do {
      try await process.start(dispatcher: dispatcher)
      guard lifecycle == .starting else {
        await process.stop()
        throw CodexRPCError.notStarted
      }
      lifecycle = .ready
    } catch {
      lifecycle = .stopped
      throw error
    }
  }

  public func initialize(
    clientInfo: CodexClientInfo,
    capabilities: InitializeCapabilities = InitializeCapabilities()
  ) async throws -> InitializeResponse {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    guard lifecycle == .ready else { throw CodexRPCError.alreadyInitialized }
    lifecycle = .initializing
    let params = InitializeParams(
      clientInfo: clientInfo,
      capabilities: capabilities
    )
    do {
      let result = try await performRequest(
        method: "initialize",
        params: JSONValue.encode(params)
      )
      let response = try result.decode(InitializeResponse.self)
      try await performNotification(method: "initialized")
      guard lifecycle == .initializing else {
        throw CodexRPCError.notStarted
      }
      lifecycle = .initialized
      return response
    } catch {
      lifecycle = .stopped
      await process.stop()
      throw error
    }
  }

  public func listModels(
    _ params: ModelListParams = ModelListParams()
  ) async throws -> ModelListResponse {
    guard lifecycle == .initialized else { throw CodexRPCError.notInitialized }
    return try await request(
      method: "model/list",
      params: params,
      response: ModelListResponse.self
    )
  }

  public func readAccount(
    _ params: GetAccountParams = GetAccountParams()
  ) async throws -> GetAccountResponse {
    try ensureInitialized()
    return try await request(
      method: "account/read",
      params: params,
      response: GetAccountResponse.self
    )
  }

  public func startChatGPTLogin() async throws -> StartChatGPTLoginResponse {
    try ensureInitialized()
    return try await request(
      method: "account/login/start",
      params: StartChatGPTLoginParams(),
      response: StartChatGPTLoginResponse.self
    )
  }

  public func cancelLogin(_ params: CancelLoginParams) async throws -> CancelLoginResponse {
    try ensureInitialized()
    return try await request(
      method: "account/login/cancel",
      params: params,
      response: CancelLoginResponse.self
    )
  }

  public func readAccountRateLimits() async throws -> GetAccountRateLimitsResponse {
    try ensureInitialized()
    return try await request(
      method: "account/rateLimits/read",
      params: EmptyCodexParams(),
      response: GetAccountRateLimitsResponse.self
    )
  }

  package func startThread(
    _ params: ThreadStartParams
  ) async throws -> ThreadStartResponse {
    try ensureInitialized()
    return try await request(
      method: "thread/start",
      params: params,
      response: ThreadStartResponse.self
    )
  }

  package func listProjects(
    _ params: ProjectListParams = ProjectListParams()
  ) async throws -> ProjectListResponse {
    try ensureInitialized()
    return try await request(
      method: "project/list",
      params: params,
      response: ProjectListResponse.self
    )
  }

  package func createProject(
    _ params: ProjectCreateParams
  ) async throws -> ProjectCreateResponse {
    try ensureInitialized()
    return try await request(
      method: "project/create",
      params: params,
      response: ProjectCreateResponse.self
    )
  }

  package func updateThreadMetadata(
    _ params: ThreadMetadataUpdateParams
  ) async throws -> ThreadMetadataUpdateResponse {
    try ensureInitialized()
    return try await request(
      method: "thread/metadata/update",
      params: params,
      response: ThreadMetadataUpdateResponse.self
    )
  }

  package func readThread(
    _ params: ThreadReadParams
  ) async throws -> ThreadReadResponse {
    try ensureInitialized()
    return try await request(
      method: "thread/read",
      params: params,
      response: ThreadReadResponse.self
    )
  }

  package func listThreads(
    _ params: ThreadListParams
  ) async throws -> ThreadListResponse {
    try ensureInitialized()
    return try await request(
      method: "thread/list",
      params: params,
      response: ThreadListResponse.self
    )
  }

  package func resumeThread(
    _ params: ThreadResumeParams
  ) async throws -> ThreadResumeResponse {
    try ensureInitialized()
    return try await request(
      method: "thread/resume",
      params: params,
      response: ThreadResumeResponse.self
    )
  }

  package func startTurn(
    _ params: TurnStartParams
  ) async throws -> TurnStartResponse {
    try ensureInitialized()
    return try await request(
      method: "turn/start",
      params: params,
      response: TurnStartResponse.self
    )
  }

  package func steerTurn(
    _ params: TurnSteerParams
  ) async throws -> TurnSteerResponse {
    try ensureInitialized()
    return try await request(
      method: "turn/steer",
      params: params,
      response: TurnSteerResponse.self
    )
  }

  package func interruptTurn(
    _ params: TurnInterruptParams
  ) async throws -> TurnInterruptResponse {
    try ensureInitialized()
    return try await request(
      method: "turn/interrupt",
      params: params,
      response: TurnInterruptResponse.self
    )
  }

  package func request<Params, Response>(
    method: String,
    params: Params,
    response: Response.Type,
    timeoutNanoseconds: UInt64? = nil
  ) async throws -> Response
  where Params: Encodable & Sendable, Response: Decodable & Sendable {
    try ensureInitialized()
    let result = try await performRequest(
      method: method,
      params: JSONValue.encode(params),
      timeoutNanoseconds: timeoutNanoseconds
    )
    return try result.decode(response)
  }

  package func request(
    method: String,
    params: JSONValue? = nil,
    timeoutNanoseconds: UInt64? = nil
  ) async throws -> JSONValue {
    try ensureInitialized()
    return try await performRequest(
      method: method,
      params: params,
      timeoutNanoseconds: timeoutNanoseconds
    )
  }

  package func sendNotification(
    method: String,
    params: JSONValue? = nil
  ) async throws {
    try ensureInitialized()
    try await performNotification(method: method, params: params)
  }

  package func respond(to id: RequestID, result: JSONValue) async throws {
    try ensureInitialized()
    try await performResponse(to: id, result: result)
  }

  package func respond(
    to id: RequestID,
    errorCode: Int64,
    message: String,
    data: JSONValue? = nil
  ) async throws {
    try ensureInitialized()
    try await process.send(
      RPCEnvelope.error(id: id, code: errorCode, message: message, data: data)
    )
  }

  func performResponse(to id: RequestID, result: JSONValue) async throws {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    try await process.send(RPCEnvelope.success(id: id, result: result))
  }

  func performRequest(
    method: String,
    params: JSONValue? = nil,
    timeoutNanoseconds: UInt64? = nil
  ) async throws -> JSONValue {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    let id = try makeRequestID()
    let message = RPCEnvelope.request(id: id, method: method, params: params)
    let process = process

    return try await dispatcher.request(
      id: id,
      method: method,
      timeoutNanoseconds: timeoutNanoseconds ?? defaultTimeoutNanoseconds
    ) {
      try await process.send(message)
    }
  }

  private func performNotification(
    method: String,
    params: JSONValue? = nil
  ) async throws {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    try await process.send(RPCEnvelope.notification(method: method, params: params))
  }

  public func stderrSnapshot() async -> Data {
    await process.stderrSnapshot()
  }

  package func terminalFailure() async -> CodexRPCError? {
    await dispatcher.terminalFailure()
  }

  public func stop() async {
    guard lifecycle != .stopped else { return }
    lifecycle = .stopped
    await process.stop()
  }

  private func makeRequestID() throws -> RequestID {
    guard nextRequestID < Int64.max else {
      throw CodexRPCError.malformedMessage("request id space exhausted")
    }
    defer { nextRequestID += 1 }
    return .integer(nextRequestID)
  }

  private func ensureInitialized() throws {
    guard lifecycle == .initialized else {
      throw CodexRPCError.notInitialized
    }
  }
}

private struct EmptyCodexParams: Codable, Sendable {}
