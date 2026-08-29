#if os(macOS)
  import Foundation

  final class XPCStreamBridge: NSObject, CodexBridgeTaskStreamListener, @unchecked Sendable {
    private let transport: XPCServiceTransport

    init(transport: XPCServiceTransport) {
      self.transport = transport
      super.init()
    }

    func push(_ payload: Data) {
      transport.deliverStreamPush(payload)
    }
  }

  final class XPCServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var streamHandlerStore: (@Sendable (Data) -> Void)?
    private var invalidated = false

    var streamHandler: (@Sendable (Data) -> Void)? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return streamHandlerStore
      }
      set {
        lock.lock()
        streamHandlerStore = newValue
        lock.unlock()
      }
    }

    init(machServiceName: String) {
      precondition(!machServiceName.isEmpty)
      let connection = NSXPCConnection(machServiceName: machServiceName)
      self.connection = connection
      configure(connection: connection)
      connection.resume()
    }

    init(endpoint: NSXPCListenerEndpoint) {
      let connection = NSXPCConnection(listenerEndpoint: endpoint)
      self.connection = connection
      configure(connection: connection)
      connection.resume()
    }

    deinit {
      connection.invalidate()
    }

    private func configure(connection: NSXPCConnection) {
      connection.remoteObjectInterface = NSXPCInterface(
        with: CodexBridgeServiceXPCProtocol.self
      )
      connection.exportedInterface = NSXPCInterface(
        with: CodexBridgeTaskStreamListener.self
      )
      connection.exportedObject = XPCStreamBridge(transport: self)
    }

    func deliverStreamPush(_ payload: Data) {
      streamHandler?(payload)
    }

    func perform(_ data: Data) async throws -> Data {
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

    func invalidate() {
      lock.lock()
      guard !invalidated else {
        lock.unlock()
        return
      }
      invalidated = true
      lock.unlock()
      connection.invalidate()
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
#endif
