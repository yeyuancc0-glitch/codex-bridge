import BridgeIPC
import Foundation

public final class BridgeServiceXPCListener: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  public enum Mode: Sendable {
    case machService(String)
    case anonymous
  }

  private let listener: NSXPCListener
  private let controller: BridgeServiceXPCController
  private let lock = NSLock()
  private var resumed = false
  private var invalidated = false

  public init(
    mode: Mode = .machService(BridgeServiceIPC.machServiceName),
    controller: BridgeServiceXPCController
  ) {
    switch mode {
    case .machService(let name):
      precondition(!name.isEmpty)
      listener = NSXPCListener(machServiceName: name)
    case .anonymous:
      listener = NSXPCListener.anonymous()
    }
    self.controller = controller
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
    lock.unlock()
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
    newConnection.exportedObject = controller
    newConnection.resume()
    return true
  }
}
