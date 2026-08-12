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

  public nonisolated let events: AsyncStream<AppServerEvent>

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
    clientInfo: CodexClientInfo
  ) async throws -> InitializeResponse {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    guard lifecycle == .ready else { throw CodexRPCError.alreadyInitialized }
    lifecycle = .initializing
    let params = InitializeParams(
      clientInfo: clientInfo,
      capabilities: InitializeCapabilities()
    )
    do {
      let response: InitializeResponse = try await request(
        method: "initialize",
        params: params,
        response: InitializeResponse.self
      )
      try await sendNotification(method: "initialized")
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

  public func request<Params, Response>(
    method: String,
    params: Params,
    response: Response.Type,
    timeoutNanoseconds: UInt64? = nil
  ) async throws -> Response
  where Params: Encodable & Sendable, Response: Decodable & Sendable {
    let result = try await request(
      method: method,
      params: JSONValue.encode(params),
      timeoutNanoseconds: timeoutNanoseconds
    )
    return try result.decode(response)
  }

  public func request(
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

  public func sendNotification(
    method: String,
    params: JSONValue? = nil
  ) async throws {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    try await process.send(RPCEnvelope.notification(method: method, params: params))
  }

  public func respond(to id: RequestID, result: JSONValue) async throws {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    try await process.send(RPCEnvelope.success(id: id, result: result))
  }

  public func respond(
    to id: RequestID,
    errorCode: Int64,
    message: String,
    data: JSONValue? = nil
  ) async throws {
    guard lifecycle.isRunning else { throw CodexRPCError.notStarted }
    try await process.send(
      RPCEnvelope.error(id: id, code: errorCode, message: message, data: data)
    )
  }

  public func stderrSnapshot() async -> Data {
    await process.stderrSnapshot()
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
}
