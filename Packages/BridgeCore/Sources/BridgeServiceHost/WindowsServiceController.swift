#if canImport(WinSDK)
  import BridgeIPC
  import BridgeIPCWindows
  import BridgePlatform
  import Foundation

  /// Per-user Named Pipe host for the shared service request controller.
  /// Each connection owns one controller and therefore one independent
  /// conversation subscription registry. Disconnect always tears it down.
  public final class WindowsServiceController: @unchecked Sendable {
    private let composition: ServiceComposition
    private let state = NSLock()
    private var controllers: [Foundation.UUID: BridgeServiceXPCController] = [:]

    private lazy var server = WindowsNamedPipeServer(
      handler: { [weak self] connectionID, request in
        await self?.dispatch(request, connectionID: connectionID)
          ?? Self.unavailableResponse()
      },
      onDisconnect: { [weak self] connectionID in
        await self?.disconnect(connectionID)
      }
    )

    public init(composition: ServiceComposition) {
      self.composition = composition
    }

    public func start() {
      server.start()
    }

    public func stop() {
      server.stop()
      let active: [BridgeServiceXPCController]
      state.lock()
      active = Array(controllers.values)
      controllers.removeAll(keepingCapacity: false)
      state.unlock()
      for controller in active { controller.stopStreaming() }
    }

    private func dispatch(_ data: Data, connectionID: Foundation.UUID) async -> Data {
      do {
        let wire = try BridgeWireMessage.decode(data)
        guard wire.kind == .request else { return Self.invalidRequestResponse() }
        let controller = controller(for: connectionID)
        let response = await controller.perform(wire.message)
        return try BridgeWireMessage(kind: .response, message: response).encoded()
      } catch {
        return Self.invalidRequestResponse()
      }
    }

    private func controller(for connectionID: Foundation.UUID) -> BridgeServiceXPCController {
      state.lock()
      defer { state.unlock() }
      if let existing = controllers[connectionID] { return existing }
      let sink = WindowsConnectionStreamSink(
        connectionID: connectionID,
        server: server
      )
      let controller = BridgeServiceXPCController(
        composition: composition,
        streamProxy: sink
      )
      controllers[connectionID] = controller
      return controller
    }

    private func disconnect(_ connectionID: Foundation.UUID) async {
      state.lock()
      let controller = controllers.removeValue(forKey: connectionID)
      state.unlock()
      controller?.stopStreaming()
    }

    private static func invalidRequestResponse() -> Data {
      response(code: "invalid_request", message: "The Named Pipe request is invalid.")
    }

    private static func unavailableResponse() -> Data {
      response(code: "unavailable", message: "The service is unavailable.", retryable: true)
    }

    private static func response(code: String, message: String, retryable: Bool = false) -> Data {
      let inner = try? BridgeServiceIPCCodec.failure(
        requestID: "invalid",
        error: BridgeServiceIPCError(
          code: code,
          message: message,
          retryable: retryable
        )
      )
      guard let inner,
        let response = try? BridgeWireMessage(kind: .response, message: inner).encoded()
      else {
        return Data(
          #"{"message":{"error":{"code":"unavailable","message":"The service is unavailable.","retryable":true},"request_id":"invalid","schema_version":3},"type":"response"}"#
            .utf8)
      }
      return response
    }
  }

  private final class WindowsConnectionStreamSink: BridgeServiceIPCStreamSink,
    @unchecked Sendable
  {
    private let connectionID: Foundation.UUID
    private weak var server: WindowsNamedPipeServer?

    init(connectionID: Foundation.UUID, server: WindowsNamedPipeServer) {
      self.connectionID = connectionID
      self.server = server
    }

    func push(_ payload: Data) {
      guard let event = try? BridgeWireMessage(kind: .event, message: payload).encoded() else {
        return
      }
      server?.push(event, to: connectionID)
    }
  }
#endif
