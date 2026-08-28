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
  private let connection: NSXPCConnection
  let streamHub = CodexBridgeTaskStreamHub()
  var invalidated = false

  public init(machServiceName: String = BridgeServiceIPC.machServiceName) {
    precondition(!machServiceName.isEmpty)
    let connection = NSXPCConnection(machServiceName: machServiceName)
    self.connection = connection
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.exportedInterface = NSXPCInterface(with: CodexBridgeTaskStreamListener.self)
    connection.exportedObject = CodexBridgeTaskStreamBridge(hub: streamHub)
    connection.resume()
  }

  public init(endpoint: NSXPCListenerEndpoint) {
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    self.connection = connection
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.exportedInterface = NSXPCInterface(with: CodexBridgeTaskStreamListener.self)
    connection.exportedObject = CodexBridgeTaskStreamBridge(hub: streamHub)
    connection.resume()
  }

  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    connection.invalidate()
    streamHub.clear()
  }

  func call<Payload: Encodable, Response: Decodable>(
    operation: BridgeServiceIPCOperation,
    payload: Payload?
  ) async throws -> Response {
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    let requestID = UUID().uuidString.lowercased()
    let data = try BridgeServiceIPCCodec.request(
      operation: operation,
      payload: payload,
      requestID: requestID
    )
    let response = try await perform(data)
    return try BridgeServiceIPCCodec.decodeResponse(
      Response.self,
      data: response,
      requestID: requestID
    )
  }

  private func perform(_ data: Data) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let completion = XPCClientCompletion(continuation)
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          completion.resume(throwing: BridgeServiceClientError.unavailable)
        }) as? CodexBridgeServiceXPCProtocol
      else {
        completion.resume(throwing: BridgeServiceClientError.invalidRemoteProxy)
        return
      }
      proxy.perform(data) { response in
        completion.resume(returning: response)
      }
    }
  }
}

private final class XPCClientCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, any Error>?

  init(_ continuation: CheckedContinuation<Data, any Error>) {
    self.continuation = continuation
  }

  func resume(returning data: Data) {
    resolve { $0.resume(returning: data) }
  }

  func resume(throwing error: any Error) {
    resolve { $0.resume(throwing: error) }
  }

  private func resolve(
    _ body: (CheckedContinuation<Data, any Error>) -> Void
  ) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    guard let continuation else { return }
    body(continuation)
  }
}
