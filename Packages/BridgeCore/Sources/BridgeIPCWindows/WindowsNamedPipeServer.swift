#if canImport(WinSDK)
  import BridgeIPC
  import BridgePlatform
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  /// Named Pipe transport carrying the bridge IPC contract on Windows.
  ///
  /// Security invariants:
  /// - The pipe is created with an explicit protected SDDL DACL granting
  ///   generic access only to the creating user and SYSTEM. Microsoft
  ///   documents that default Named Pipe descriptors can grant Everyone or
  ///   anonymous read access, so relying on defaults is not acceptable.
  /// - Remote clients are rejected (`PIPE_REJECT_REMOTE_CLIENTS`), and every
  ///   accepted connection additionally proves its client-process user SID
  ///   matches the server's own user; anything unprovable is disconnected.
  /// - Frame length headers are validated against the shared contract limit
  ///   before any body allocation; violations drop the connection.
  public final class WindowsNamedPipeServer: @unchecked Sendable {
    public typealias Handler =
      @Sendable (
        _ connectionID: Foundation.UUID,
        _ request: Data
      ) async -> Data
    public typealias DisconnectHandler = @Sendable (Foundation.UUID) async -> Void

    private enum Constants {
      // Inlined Win32 values; several are macros the Swift bindings do not
      // export (same class of issue as commit 05044c4).
      static let openMode = DWORD(0x0000_0003)
      static let firstPipeInstance = DWORD(0x0008_0000)
      // dwPipeMode: PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE
      //            | PIPE_REJECT_REMOTE_CLIENTS.
      static let pipeMode = DWORD(0x0000_000E)
      static let pipeUnlimitedInstances = DWORD(0x0000_00FF)
      static let errorPipeConnected = DWORD(539)
      static let errorMoreData = DWORD(234)
      static let errorNoData = DWORD(232)
      static let errorBrokenPipe = DWORD(109)
      static let sddlRevision = DWORD(1)
      static let bufferSize = DWORD(256 * 1_024)
    }

    private let path: String
    private let handler: Handler
    private let disconnectHandler: DisconnectHandler
    private let maximumConnections: Int
    private let responseTimeout: TimeInterval
    private let state = NSCondition()
    private var connections: [Foundation.UUID: Connection] = [:]
    private var started = false
    private var stopped = false
    private var acceptLoopRunning = false

    public init(
      path: String = BridgeServiceIPC.windowsPipeName,
      maximumConnections: Int = 32,
      responseTimeout: TimeInterval = 60,
      handler: @escaping Handler,
      onDisconnect: @escaping DisconnectHandler = { _ in }
    ) {
      precondition((1...Int(Constants.pipeUnlimitedInstances)).contains(maximumConnections))
      precondition(responseTimeout > 0)
      self.path = path
      self.maximumConnections = maximumConnections
      self.responseTimeout = responseTimeout
      self.handler = handler
      disconnectHandler = onDisconnect
    }

    public func start() {
      state.lock()
      if stopped || started {
        state.unlock()
        return
      }
      started = true
      acceptLoopRunning = true
      state.unlock()
      Thread.detachNewThread { [weak self] in
        self?.acceptLoop()
      }
    }

    public func stop() {
      let active: [Connection]
      let shouldWakeAcceptLoop: Bool
      state.lock()
      stopped = true
      active = Array(connections.values)
      connections.removeAll(keepingCapacity: false)
      shouldWakeAcceptLoop = acceptLoopRunning
      state.unlock()
      for connection in active {
        connection.close()
        notifyDisconnected(connection.id)
      }
      // Wake an accept thread parked in ConnectNamedPipe with a throwaway
      // local client. A shutdown wakeup never enters the framed protocol or
      // waits for a response, so stop cannot deadlock behind its own server.
      if shouldWakeAcceptLoop {
        wakeAcceptLoop()
        waitForAcceptLoopExit()
      }
    }

    func dispatch(request: Data, connectionID: Foundation.UUID) async -> Data {
      await handler(connectionID, request)
    }

    @discardableResult
    public func push(_ payload: Data, to connectionID: Foundation.UUID) -> Bool {
      state.lock()
      let connection = connections[connectionID]
      state.unlock()
      return connection?.push(payload) == true
    }

    func register(_ connection: Connection) {
      state.lock()
      if stopped || connections.count >= maximumConnections {
        state.unlock()
        connection.close()
        return
      }
      connections[connection.id] = connection
      state.unlock()
      Thread.detachNewThread { [weak self, connection] in
        connection.readLoop()
        self?.unregister(connection)
      }
    }

    private func unregister(_ connection: Connection) {
      state.lock()
      let removed = connections.removeValue(forKey: connection.id) != nil
      state.unlock()
      if removed { notifyDisconnected(connection.id) }
    }

    private func notifyDisconnected(_ connectionID: Foundation.UUID) {
      Task { [disconnectHandler] in
        await disconnectHandler(connectionID)
      }
    }

    private func acceptLoop() {
      defer {
        state.lock()
        acceptLoopRunning = false
        state.broadcast()
        state.unlock()
      }
      var isFirstInstance = true
      while true {
        state.lock()
        let shouldStop = stopped
        state.unlock()
        if shouldStop { return }

        guard
          let instance = Self.createPipeInstance(
            path: path,
            requireFirstInstance: isFirstInstance
          )
        else {
          Thread.sleep(forTimeInterval: 0.05)
          continue
        }
        isFirstInstance = false
        state.lock()
        if stopped {
          state.unlock()
          CloseHandle(instance)
          return
        }
        state.unlock()
        var connected = ConnectNamedPipe(instance, nil)
        let connectError = connected ? DWORD(0) : GetLastError()
        if !connected, connectError == Constants.errorPipeConnected {
          connected = true
        }
        guard connected, let peerSID = Self.clientUserSIDString(instance),
          Self.isCurrentUserSID(peerSID)
        else {
          DisconnectNamedPipe(instance)
          CloseHandle(instance)
          continue
        }
        register(Connection(handle: instance, server: self, peerUserSID: peerSID))
      }
    }

    private func waitForAcceptLoopExit() {
      let deadline = Date().addingTimeInterval(2)
      state.lock()
      defer { state.unlock() }
      while acceptLoopRunning {
        if !state.wait(until: deadline) { return }
      }
    }

    private func wakeAcceptLoop() {
      let name = WideBuffer(path)
      for attempt in 0..<100 {
        state.lock()
        let isRunning = acceptLoopRunning
        state.unlock()
        if !isRunning { return }
        let handle = CreateFileW(
          name.pointer,
          DWORD(0xC000_0000),
          0,
          nil,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
        if let handle, handle != INVALID_HANDLE_VALUE {
          CloseHandle(handle)
          return
        }
        if attempt < 99 { Thread.sleep(forTimeInterval: 0.02) }
      }
    }

    static func createPipeInstance(path: String, requireFirstInstance: Bool = false) -> HANDLE? {
      guard let descriptor = currentUserSDLSecurityDescriptor() else { return nil }
      var attributes = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor.pointer,
        bInheritHandle: false
      )
      let name = WideBuffer(path)
      let handle = CreateNamedPipeW(
        name.pointer,
        Constants.openMode | (requireFirstInstance ? Constants.firstPipeInstance : 0),
        Constants.pipeMode,
        Constants.pipeUnlimitedInstances,
        Constants.bufferSize,
        Constants.bufferSize,
        0,
        &attributes
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
      return handle
    }

    /// Returns the connected client's user SID string, or nil when identity
    /// cannot be proven. Fail-closed by construction.
    static func clientUserSIDString(_ pipe: HANDLE) -> String? {
      var processID: ULONG = 0
      guard GetNamedPipeClientProcessId(pipe, &processID) else { return nil }
      guard
        let process = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(processID)
        )
      else { return nil }
      defer { CloseHandle(process) }
      guard let sidString = WindowsSecurity.processUserSIDString(process) else { return nil }
      return sidString.value
    }

    static func isCurrentUserSID(_ peerSID: String) -> Bool {
      guard let current = WindowsSecurity.currentUserSIDString() else { return false }
      return current.value.caseInsensitiveCompare(peerSID) == .orderedSame
    }

    static func currentUserSDLSecurityDescriptor() -> SecurityDescriptorBox? {
      guard let sidString = WindowsSecurity.currentUserSIDString() else { return nil }
      let sddl = WindowsSecurity.ownerOnlySDDL(userSID: sidString.value)
      var descriptor: UnsafeMutableRawPointer?
      let sddlWide = WideBuffer(sddl)
      guard
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddlWide.pointer,
          Constants.sddlRevision,
          &descriptor,
          nil
        ), let descriptor
      else { return nil }
      return SecurityDescriptorBox(pointer: descriptor)
    }

    final class Connection: @unchecked Sendable {
      let id = Foundation.UUID()

      let peerUserSID: String
      private let weakServer: WeakServer
      private let ioLock = NSLock()
      private var handle: HANDLE?

      init(handle: HANDLE, server: WindowsNamedPipeServer, peerUserSID: String) {
        self.handle = handle
        weakServer = WeakServer(server)
        self.peerUserSID = peerUserSID
      }

      /// Server-pushed event frame (task conversation updates and similar).
      func push(_ payload: Data) -> Bool {
        do {
          try send(payload)
          return true
        } catch {
          return false
        }
      }

      func close() {
        ioLock.lock()
        let current = handle
        handle = nil
        ioLock.unlock()
        guard let current else { return }
        CancelIoEx(current, nil)
        DisconnectNamedPipe(current)
        CloseHandle(current)
      }

      func readLoop() {
        while true {
          ioLock.lock()
          let current = handle
          ioLock.unlock()
          guard let current else { return }

          var header = [UInt8](repeating: 0, count: BridgeWireFraming.headerByteCount)
          guard readExactly(handle: current, buffer: &header) else {
            close()
            return
          }
          do {
            let length = try BridgeWireFraming.declaredLength(Data(header))
            var body = [UInt8](repeating: 0, count: length)
            if length > 0 {
              guard readExactly(handle: current, buffer: &body) else {
                close()
                return
              }
            }
            guard dispatchAndSend(Data(body)) else { return }
          } catch {
            // Protocol violation (oversize declaration): drop the client.
            close()
            return
          }
        }
      }

      func send(_ message: Data) throws {
        let frame = try BridgeWireFraming.frame(message)
        try frame.withUnsafeBytes { bytes in
          ioLock.lock()
          let current = handle
          guard let current else {
            ioLock.unlock()
            throw PipeTransportError.connectionClosed
          }
          var offset = 0
          while offset < frame.count {
            var written = DWORD(0)
            let ok = WriteFile(
              current,
              bytes.baseAddress!.advanced(by: offset),
              DWORD(frame.count - offset),
              &written,
              nil
            )
            if !ok || written == 0 {
              handle = nil
              ioLock.unlock()
              DisconnectNamedPipe(current)
              CloseHandle(current)
              throw PipeTransportError.connectionClosed
            }
            offset += Int(written)
          }
          ioLock.unlock()
        }
      }

      /// Keeps one request/response transaction in flight per connection.
      /// A synchronous Named Pipe handle must not start its next blocking
      /// read while another task writes the current response.
      private func dispatchAndSend(_ request: Data) -> Bool {
        let completion = ResponseCompletion()
        Task.detached(priority: .userInitiated) { [weakServer, id] in
          defer { completion.finish() }
          guard let server = weakServer.value else { return }
          let response = await server.dispatch(request: request, connectionID: id)
          do {
            try self.send(response)
          } catch {
            self.close()
          }
        }
        guard completion.wait(timeout: weakServer.value?.responseTimeout ?? 0) else {
          close()
          return false
        }
        return true
      }

      private func readExactly(handle: HANDLE, buffer: inout [UInt8]) -> Bool {
        var received = DWORD(0)
        var offset = 0
        while offset < buffer.count {
          let remaining = buffer.count - offset
          let (ok, readError) = buffer.withUnsafeMutableBytes { raw in
            let succeeded = ReadFile(
              handle,
              raw.baseAddress!.advanced(by: offset),
              DWORD(remaining),
              &received,
              nil
            )
            return (succeeded, succeeded ? DWORD(0) : GetLastError())
          }
          if ok || readError == Constants.errorMoreData {
            guard received > 0 else { return false }
            offset += Int(received)
            continue
          }
          return false
        }
        return true
      }
    }

    struct WeakServer: @unchecked Sendable {
      weak var value: WindowsNamedPipeServer?

      init(_ value: WindowsNamedPipeServer) {
        self.value = value
      }
    }

    private final class ResponseCompletion: @unchecked Sendable {
      private let condition = NSCondition()
      private var finished = false

      func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
      }

      func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !finished, condition.wait(until: deadline) {}
        let result = finished
        condition.unlock()
        return result
      }
    }
  }

  final class SecurityDescriptorBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(pointer: UnsafeMutableRawPointer) {
      self.pointer = pointer
    }

    deinit {
      LocalFree(pointer)
    }
  }
#endif
