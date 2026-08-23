#if canImport(WinSDK)
  /// Transport-level failure reasons shared by the pipe server and test client.
  enum PipeTransportError: Error, Equatable {
    case connectionFailed(Int32)
    case connectionClosed
    case invalidFrame
  }
#endif
