import Foundation

public enum BridgeServiceClientError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case invalidRemoteProxy
  case responseFailed

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Codex Bridge Service is unavailable."
    case .invalidRemoteProxy:
      "Codex Bridge Service returned an invalid XPC proxy."
    case .responseFailed:
      "Codex Bridge Service did not return a valid response."
    }
  }
}

public actor BridgeServiceClient {
  private let transport: any ServiceRequestTransport
  let streamHub = CodexBridgeTaskStreamHub()
  var invalidated = false
  var conversationStreamTokens: [String: [Int: UUID]] = [:]

  public init(transport: any ServiceRequestTransport) {
    self.transport = transport
    transport.streamHandler = { [streamHub] payload in
      streamHub.push(payload)
    }
  }

  #if os(macOS)
    public init(machServiceName: String = BridgeServiceIPC.machServiceName) {
      precondition(!machServiceName.isEmpty)
      self.init(transport: XPCServiceTransport(machServiceName: machServiceName))
    }

    public init(endpoint: NSXPCListenerEndpoint) {
      self.init(transport: XPCServiceTransport(endpoint: endpoint))
    }
  #endif

  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    transport.invalidate()
    conversationStreamTokens.removeAll(keepingCapacity: false)
    streamHub.clear()
  }

  func call<Payload: Encodable, Response: Decodable>(
    operation: BridgeServiceIPCOperation,
    payload: Payload?
  ) async throws -> Response {
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    #if os(Windows)
      WindowsIPCTrace.record("client.\(operation.rawValue).begin")
    #endif
    let requestID = UUID().uuidString.lowercased()
    let data = try BridgeServiceIPCCodec.request(
      operation: operation,
      payload: payload,
      requestID: requestID
    )
    let response = try await perform(data)
    #if os(Windows)
      WindowsIPCTrace.record("client.\(operation.rawValue).response")
    #endif
    return try BridgeServiceIPCCodec.decodeResponse(
      Response.self,
      data: response,
      requestID: requestID
    )
  }

  private func perform(_ data: Data) async throws -> Data {
    try await transport.perform(data)
  }
}
