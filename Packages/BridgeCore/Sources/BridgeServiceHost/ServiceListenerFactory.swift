import BridgeIPC
import Foundation

/// Transport-neutral listener accepting shell connections for the background
/// service: launchd Mach XPC on macOS, a local named pipe on Windows.
public protocol ServiceRequestListener: AnyObject, Sendable {
  func resume()
  func invalidate()
}

public enum ServiceListenerFactory {
  public static func makeListener(
    composition: ServiceComposition
  ) -> any ServiceRequestListener {
    #if os(macOS)
      return BridgeServiceXPCListener(
        mode: .machService(BridgeServiceIPC.machServiceName),
        composition: composition
      )
    #elseif os(Windows)
      return BridgeServicePipeListener(
        pipeName: BridgeServiceIPC.windowsPipeName,
        composition: composition
      )
    #else
      fatalError("No service listener for this platform.")
    #endif
  }
}
