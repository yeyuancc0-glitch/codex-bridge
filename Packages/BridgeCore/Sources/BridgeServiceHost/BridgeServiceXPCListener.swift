import BridgeIPC
import BridgeIPCMacOS
import Foundation

public final class BridgeServiceXPCListener: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  public enum Mode: Sendable {
    case machService(String)
    case anonymous
  }

  private let listener: NSXPCListener
  private let makeController: ((any BridgeServiceIPCStreamSink)?) -> BridgeServiceXPCController
  private let lock = NSLock()
  private var controllers: [NSXPCConnection: BridgeServiceXPCAdapter] = [:]
  private var resumed = false
  private var invalidated = false

  public init(
    mode: Mode = .machService(BridgeServiceIPC.machServiceName),
    composition: ServiceComposition
  ) {
    switch mode {
    case .machService(let name):
      precondition(!name.isEmpty)
      listener = NSXPCListener(machServiceName: name)
    case .anonymous:
      listener = NSXPCListener.anonymous()
    }
    self.makeController = { streamProxy in
      BridgeServiceXPCController(composition: composition, streamProxy: streamProxy)
    }
    super.init()
    listener.delegate = self
  }

  public var endpoint: NSXPCListenerEndpoint? {
    listener.endpoint
  }

  public func resume() {
    lock.lock()
    guard !resumed, !invalidated else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    listener.resume()
  }

  public func invalidate() {
    lock.lock()
    guard !invalidated else {
      lock.unlock()
      return
    }
    invalidated = true
    let active = controllers.values.map(\.controller)
    controllers.removeAll(keepingCapacity: false)
    lock.unlock()
    for controller in active {
      controller.stopStreaming()
    }
    listener.invalidate()
  }

  public func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    _ = listener
    newConnection.exportedInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    newConnection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeTaskStreamListener.self
    )
    let remote = newConnection.remoteObjectProxy as? CodexBridgeTaskStreamListener
    let controller = makeController(remote.map(BridgeServiceXPCStreamSink.init(listener:)))
    let adapter = BridgeServiceXPCAdapter(controller: controller)
    newConnection.exportedObject = adapter
    lock.lock()
    controllers[newConnection] = adapter
    lock.unlock()
    newConnection.invalidationHandler = { [weak self] in
      self?.remove(newConnection)
    }
    newConnection.resume()
    return true
  }

  private func remove(_ connection: NSXPCConnection) {
    lock.lock()
    let controller = controllers.removeValue(forKey: connection)?.controller
    lock.unlock()
    controller?.stopStreaming()
  }
}
