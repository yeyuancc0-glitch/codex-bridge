#if canImport(WinSDK)
  import BridgePlatform
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  /// Minimal Named Pipe client mirroring the server's framing. Used by the
  /// Windows transport tests; the production client is the C# WinUI app.
  public enum WindowsNamedPipeClient {
    /// Opens a connection, sends one request frame, reads exactly one
    /// response frame, and closes.
    public static func transact(path: String, request: Data) throws -> Data {
      let connection = try connect(path: path)
      defer { connection.close() }
      try connection.send(request)
      return try connection.receive(timeout: 5)
    }

    public static func connect(path: String) throws -> PipeConnection {
      let name = WideBuffer(path)
      let handle = CreateFileW(
        name.pointer,
        // GENERIC_READ | GENERIC_WRITE.
        DWORD(0xC000_0000),
        0,
        nil,
        DWORD(OPEN_EXISTING),
        0,
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PipeTransportError.connectionFailed(Int32(GetLastError()))
      }
      var mode = Constants.pipeReadmodeMessage
      guard SetNamedPipeHandleState(handle, &mode, nil, nil) else {
        let code = GetLastError()
        CloseHandle(handle)
        throw PipeTransportError.connectionFailed(Int32(code))
      }
      return PipeConnection(handle: handle)
    }

    private enum Constants {
      static let pipeReadmodeMessage = DWORD(0x0000_0002)
      static let errorMoreData = DWORD(234)
      static let errorBrokenPipe = DWORD(109)
      static let errorNoData = DWORD(232)
    }

    public final class PipeConnection {
      private let ioLock = NSLock()
      private var handle: HANDLE?

      init(handle: HANDLE) {
        self.handle = handle
      }

      public func close() {
        ioLock.lock()
        let current = handle
        handle = nil
        ioLock.unlock()
        guard let current else { return }
        CloseHandle(current)
      }

      public func send(_ message: Data) throws {
        let frame = try BridgeWireFraming.frame(message)
        try sendRawFrameForTesting(frame)
      }

      func sendRawFrameForTesting(_ frame: Data) throws {
        try frame.withUnsafeBytes { bytes in
          var offset = 0
          while offset < frame.count {
            var written = DWORD(0)
            let ok = WriteFile(
              rawHandle(),
              bytes.baseAddress!.advanced(by: offset),
              DWORD(frame.count - offset),
              &written,
              nil
            )
            if !ok || written == 0 {
              throw PipeTransportError.connectionClosed
            }
            offset += Int(written)
          }
        }
      }

      public func receive() throws -> Data {
        var accumulated = Data()
        while true {
          let capacity = 64 * 1_024
          var chunk = [UInt8](repeating: 0, count: capacity)
          var received = DWORD(0)
          let ok = chunk.withUnsafeMutableBytes { raw in
            ReadFile(rawHandle(), raw.baseAddress, DWORD(capacity), &received, nil)
          }
          if ok || GetLastError() == Constants.errorMoreData {
            guard received > 0 else { break }
            accumulated.append(contentsOf: chunk.prefix(Int(received)))
            // A clean return means the complete message arrived.
            if ok { break }
            continue
          }
          let code = GetLastError()
          if code == Constants.errorBrokenPipe || code == Constants.errorNoData {
            break
          }
          throw PipeTransportError.connectionClosed
        }
        let (frames, consumed) = try BridgeWireFraming.extractFrames(from: accumulated)
        guard frames.count == 1, consumed == accumulated.count else {
          throw PipeTransportError.invalidFrame
        }
        return frames[0]
      }

      func receive(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
          var available = DWORD(0)
          guard PeekNamedPipe(rawHandle(), nil, 0, nil, &available, nil) else {
            throw PipeTransportError.connectionClosed
          }
          if available > 0 { return try receive() }
          Thread.sleep(forTimeInterval: 0.01)
        }
        throw PipeTransportError.deadlineExceeded
      }

      private func rawHandle() -> HANDLE {
        ioLock.lock()
        defer { ioLock.unlock() }
        return handle!
      }
    }
  }
#endif
