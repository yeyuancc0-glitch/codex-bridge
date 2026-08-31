import Foundation

/// Wire-level request/response transport between the desktop shell and the
/// background service. macOS uses XPC; Windows uses a named pipe.
public protocol ServiceRequestTransport: AnyObject, Sendable {
  /// Frames pushed by the service outside of a request/response exchange,
  /// such as live conversation stream updates.
  var streamHandler: (@Sendable (Data) -> Void)? { get set }
  func perform(_ data: Data) async throws -> Data
  func invalidate()
}

/// Server-side channel for pushing stream frames to one connected shell.
public protocol ServiceStreamSink: AnyObject, Sendable {
  func push(_ payload: Data)
}

/// Creates the platform default transport for talking to the background
/// service: launchd Mach XPC on macOS, the local named pipe on Windows.
public enum ServiceTransportFactory {
  public static func defaultTransport() -> any ServiceRequestTransport {
    #if os(macOS)
      return XPCServiceTransport(machServiceName: BridgeServiceIPC.machServiceName)
    #elseif os(Windows)
      return NamedPipeServiceTransport(pipeName: BridgeServiceIPC.windowsPipeName)
    #else
      fatalError("Service transport is unavailable on this platform.")
    #endif
  }
}
