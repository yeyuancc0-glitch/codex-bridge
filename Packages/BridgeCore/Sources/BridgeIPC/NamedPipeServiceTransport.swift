#if os(Windows)
  import Foundation
  import WinSDK

  /// Named pipe transport for the Windows desktop shell.
  ///
  /// Frame layout on the pipe: one kind byte (0 request, 1 response, 2 stream
  /// push), a UInt32 little-endian payload length, then the payload. Responses
  /// are matched to requests in FIFO order; the server preserves per-connection
  /// response ordering.
  final class NamedPipeServiceTransport: ServiceRequestTransport, @unchecked Sendable {
    private let pipeName: String
    private let lock = NSLock()
    private var handle: HANDLE = INVALID_HANDLE_VALUE
    private var readerThread: Thread?
    private var pending: [CheckedContinuation<Data, any Error>] = []
    private var invalidated = false

    var streamHandler: (@Sendable (Data) -> Void)?

    init(pipeName: String) {
      self.pipeName = pipeName
    }

    deinit {
      closeHandle()
    }

    func perform(_ data: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if invalidated {
          lock.unlock()
          continuation.resume(throwing: BridgeServiceClientError.unavailable)
          return
        }
        do {
          try connectIfNeededLocked()
          try writeFrameLocked(kind: 0, payload: data)
          pending.append(continuation)
        } catch {
          lock.unlock()
          closeHandle()
          continuation.resume(throwing: BridgeServiceClientError.unavailable)
          return
        }
        lock.unlock()
      }
    }

    func invalidate() {
      lock.lock()
      invalidated = true
      lock.unlock()
      closeHandle()
    }

    private func connectIfNeededLocked() throws {
      guard handle == INVALID_HANDLE_VALUE else { return }
      var opened = openPipe()
      for _ in 0..<50 where opened == INVALID_HANDLE_VALUE {
        guard GetLastError() == ERROR_PIPE_BUSY else { break }
        pipeName.withCString(encodedAs: UTF16.self) { name in
          _ = WaitNamedPipeW(name, 100)
        }
        opened = openPipe()
      }
      guard opened != INVALID_HANDLE_VALUE else {
        throw BridgeServiceClientError.unavailable
      }
      handle = opened
      pending.removeAll()
      let thread = Thread { [weak self] in
        self?.readLoop()
      }
      thread.name = "codex-bridge.pipe-reader"
      thread.stackSize = 1 << 20
      readerThread = thread
      thread.start()
    }

    private func openPipe() -> HANDLE {
      pipeName.withCString(encodedAs: UTF16.self) { name in
        CreateFileW(
          name,
          DWORD(0x8000_0000) | DWORD(0x4000_0000), /* GENERIC_READ | GENERIC_WRITE */
          0,
          nil,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
      }
    }

    private func writeFrameLocked(kind: UInt8, payload: Data) throws {
      var frame = Data([kind])
      var length = UInt32(payload.count).littleEndian
      withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
      frame.append(payload)
      try frame.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          var written: DWORD = 0
          guard
            WriteFile(
              handle,
              UnsafeRawPointer(raw.baseAddress!).advanced(by: offset),
              DWORD(raw.count - offset),
              &written,
              nil
            ), written > 0
          else {
            throw BridgeServiceClientError.unavailable
          }
          offset += Int(written)
        }
      }
    }

    private func readLoop() {
      while true {
        lock.lock()
        let current = handle
        lock.unlock()
        guard current != INVALID_HANDLE_VALUE else { return }
        guard let frame = readFrame(current) else {
          failPendingAndClose()
          return
        }
        deliver(frame)
      }
    }

    private func readFrame(_ handle: HANDLE) -> (kind: UInt8, payload: Data)? {
      guard let header = readFully(handle, 5) else { return nil }
      let kind = header[header.startIndex]
      let length = header.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
      }
      guard length <= BridgeServiceIPC.maximumMessageBytes else { return nil }
      guard let payload = readFully(handle, length) else { return nil }
      return (kind, payload)
    }

    private func readFully(_ handle: HANDLE, _ count: UInt32) -> Data? {
      guard count > 0 else { return Data() }
      var buffer = Data(count: Int(count))
      let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
        var total: UInt32 = 0
        while total < count {
          var read: DWORD = 0
          guard
            ReadFile(
              handle,
              raw.baseAddress!.advanced(by: Int(total)),
              count - total,
              &read,
              nil
            ), read > 0
          else { return false }
          total += read
        }
        return true
      }
      return ok ? buffer : nil
    }

    private func deliver(_ frame: (kind: UInt8, payload: Data)) {
      switch frame.kind {
      case 1:
        lock.lock()
        let continuation = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        continuation?.resume(returning: frame.payload)
      case 2:
        streamHandler?(frame.payload)
      default:
        break
      }
    }

    private func failPendingAndClose() {
      lock.lock()
      let failed = pending
      pending.removeAll()
      lock.unlock()
      for continuation in failed {
        continuation.resume(throwing: BridgeServiceClientError.unavailable)
      }
      closeHandle()
    }

    private func closeHandle() {
      lock.lock()
      let current = handle
      handle = INVALID_HANDLE_VALUE
      lock.unlock()
      guard current != INVALID_HANDLE_VALUE else { return }
      _ = CloseHandle(current)
    }
  }
#endif
