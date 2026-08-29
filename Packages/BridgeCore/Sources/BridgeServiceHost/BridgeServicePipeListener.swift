#if os(Windows)
  import BridgeIPC
  import Foundation
  import WinSDK

  /// Named pipe listener for the Windows background service.
  ///
  /// Wire format per frame: one kind byte (0 request, 1 response, 2 stream
  /// push), a UInt32 little-endian payload length, then the payload. Requests
  /// on one connection are answered strictly in arrival order so the shell can
  /// match responses FIFO; stream pushes are interleaved as kind-2 frames.
  final class BridgeServicePipeListener: ServiceRequestListener, @unchecked Sendable {
    private let pipeName: String
    private let composition: ServiceComposition
    private let lock = NSLock()
    private var acceptThread: Thread?
    private var running = false
    private var connections: [PipeConnection] = []

    init(pipeName: String, composition: ServiceComposition) {
      self.pipeName = pipeName
      self.composition = composition
    }

    func resume() {
      lock.lock()
      guard !running else {
        lock.unlock()
        return
      }
      running = true
      let thread = Thread { [weak self] in
        self?.acceptLoop()
      }
      thread.name = "codex-bridge.pipe-listener"
      acceptThread = thread
      lock.unlock()
      thread.start()
    }

    func invalidate() {
      lock.lock()
      running = false
      let active = connections
      connections.removeAll()
      lock.unlock()
      for connection in active {
        connection.close()
      }
    }

    private func acceptLoop() {
      while isRunning() {
        guard let handle = createPipeInstance() else {
          Thread.sleep(forTimeInterval: 0.1)
          continue
        }
        if !ConnectNamedPipe(handle, nil) {
          let error = GetLastError()
          // ERROR_PIPE_CONNECTED: the client connected between creation and
          // ConnectNamedPipe, which still yields a usable session.
          guard error == ERROR_PIPE_CONNECTED, isRunning() else {
            _ = CloseHandle(handle)
            if !isRunning() { break }
            continue
          }
        }
        guard isRunning() else {
          _ = CloseHandle(handle)
          break
        }
        let writer = PipeFrameWriter(handle: handle)
        let controller = BridgeServiceRequestController(
          composition: composition,
          streamSink: PipeStreamSink(writer: writer)
        )
        let connection = PipeConnection(handle: handle, writer: writer, controller: controller)
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start { [weak self] connection in
          self?.remove(connection)
        }
      }
    }

    private func isRunning() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return running
    }

    private func remove(_ connection: PipeConnection) {
      lock.lock()
      connections.removeAll { $0 === connection }
      lock.unlock()
    }

    private func createPipeInstance() -> HANDLE? {
      pipeName.withCString(encodedAs: UTF16.self) { name in
        let handle = CreateNamedPipeW(
          name,
          DWORD(PIPE_ACCESS_DUPLEX),
          DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
          DWORD(PIPE_UNLIMITED_INSTANCES),
          DWORD(BridgeServiceIPC.maximumMessageBytes),
          DWORD(BridgeServiceIPC.maximumMessageBytes),
          DWORD(0),
          nil
        )
        return handle == INVALID_HANDLE_VALUE ? nil : handle
      }
    }
  }

  /// Serializes all frame writes (responses and stream pushes) on one pipe.
  final class PipeFrameWriter: @unchecked Sendable {
    private let handle: HANDLE
    private let lock = NSLock()

    init(handle: HANDLE) {
      self.handle = handle
    }

    func write(kind: UInt8, payload: Data) -> Bool {
      var frame = Data([kind])
      var length = UInt32(payload.count).littleEndian
      withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
      frame.append(payload)
      return frame.withUnsafeBytes { raw -> Bool in
        lock.lock()
        defer { lock.unlock() }
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
          else { return false }
          offset += Int(written)
        }
        return true
      }
    }
  }

  /// One connected shell session: serves requests on a dedicated thread.
  private final class PipeConnection: @unchecked Sendable {
    private let handle: HANDLE
    private let writer: PipeFrameWriter
    private let controller: BridgeServiceRequestController

    init(handle: HANDLE, writer: PipeFrameWriter, controller: BridgeServiceRequestController) {
      self.handle = handle
      self.writer = writer
      self.controller = controller
    }

    func start(closeCallback: @escaping @Sendable (PipeConnection) -> Void) {
      let thread = Thread { [weak self] in
        self?.serve(closeCallback: closeCallback)
      }
      thread.name = "codex-bridge.pipe-session"
      thread.stackSize = 1 << 20
      thread.start()
    }

    private func serve(closeCallback: @escaping @Sendable (PipeConnection) -> Void) {
      defer { closeCallback(self) }
      while true {
        guard let (kind, payload) = readFrame() else { return }
        guard kind == 0 else {
          // Only requests are accepted from the shell.
          return
        }
        let response = dispatchSync(payload)
        guard writer.write(kind: 1, payload: response) else { return }
      }
    }

    /// Bridges the async controller dispatch onto the blocking session thread.
    private func dispatchSync(_ payload: Data) -> Data {
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var response: Data?
      let controller = controller
      Task {
        response = await controller.dispatch(payload)
        semaphore.signal()
      }
      semaphore.wait()
      return response ?? Data()
    }

    private func readFrame() -> (kind: UInt8, payload: Data)? {
      guard let header = readFully(5) else { return nil }
      let kind = header[header.startIndex]
      let length = header.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
      }
      guard length <= BridgeServiceIPC.maximumMessageBytes else { return nil }
      guard let payload = readFully(length) else { return nil }
      return (kind, payload)
    }

    private func readFully(_ count: UInt32) -> Data? {
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

    func close() {
      _ = CloseHandle(handle)
    }
  }

  /// Streams controller pushes to the connected shell as kind-2 frames.
  private final class PipeStreamSink: ServiceStreamSink, @unchecked Sendable {
    private let writer: PipeFrameWriter

    init(writer: PipeFrameWriter) {
      self.writer = writer
    }

    func push(_ payload: Data) {
      _ = writer.write(kind: 2, payload: payload)
    }
  }
#endif
