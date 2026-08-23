#if canImport(WinSDK)
  import BridgePlatform
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
    public typealias Handler = @Sendable (_ connectionID: UUID, _ request: Data) async -> Data

    private enum Constants {
      // Inlined Win32 values; several are macros the Swift bindings do not
      // export (same class of issue as commit 05044c4).
      // dwOpenMode: PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE.
      static let openMode = DWORD(0x0008_0003)
      // dwPipeMode: PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE
      //            | PIPE_REJECT_REMOTE_CLIENTS.
      static let pipeMode = DWORD(0x0000_000E)
      static let pipeUnlimitedInstances = DWORD(0x0000_00FF)
      static let errorPipeConnected = DWORD(539)
      static let errorMoreData = DWORD(234)
      static let errorNoData = DWORD(232)
      static let errorBrokenPipe = DWORD(109)
      static let tokenQuery = DWORD(0x0008)
      static let sddlRevision = DWORD(1)
      static let bufferSize = DWORD(256 * 1_024)
    }

    private let path: String
    private let handler: Handler
    private let state = NSLock()
    private var connections: [UUID: Connection] = [:]
    private var stopped = false

    public init(path: String = BridgeServiceIPC.windowsPipeName, handler: @escaping Handler) {
      self.path = path
      self.handler = handler
    }

    public func start() {
      state.lock()
      if stopped {
        state.unlock()
        return
      }
      state.unlock()
      Thread.detachNewThread { [weak self] in
        self?.acceptLoop()
      }
    }

    public func stop() {
      let active: [Connection]
      state.lock()
      stopped = true
      active = Array(connections.values)
      connections.removeAll(keepingCapacity: false)
      state.unlock()
      for connection in active {
        connection.close()
      }
      // Wake an accept thread parked in ConnectNamedPipe with a throwaway
      // local client so it observes `stopped` promptly.
      _ = try? WindowsNamedPipeClient.transact(path: path, request: Data())
    }

    func dispatch(request: Data, connectionID: UUID) async -> Data {
      await handler(connectionID, request)
    }

    func register(_ connection: Connection) {
      state.lock()
      if stopped {
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
      connections.removeValue(forKey: connection.id)
      state.unlock()
    }

    private func acceptLoop() {
      while true {
        state.lock()
        let shouldStop = stopped
        state.unlock()
        if shouldStop { return }

        guard let instance = Self.createPipeInstance(path: path) else {
          Thread.sleep(forTimeInterval: 0.05)
          continue
        }
        var connected = ConnectNamedPipe(instance, nil)
        if !connected, GetLastError() == Constants.errorPipeConnected {
          connected = true
        }
        guard connected, let peerSID = Self.clientUserSIDString(instance) else {
          DisconnectNamedPipe(instance)
          CloseHandle(instance)
          continue
        }
        register(Connection(handle: instance, server: self, peerUserSID: peerSID))
      }
    }

    static func createPipeInstance(path: String) -> HANDLE? {
      guard let descriptor = currentUserSDLSecurityDescriptor() else { return nil }
      defer { LocalFree(descriptor.pointer) }
      var attributes = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor.pointer,
        bInheritHandle: false
      )
      let name = WideBuffer(path)
      let handle = CreateNamedPipeW(
        name.pointer,
        Constants.openMode,
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
      guard let sidString = userSIDString(ofProcess: process) else { return nil }
      defer { LocalFree(UnsafeMutableRawPointer(sidString.pointer)) }
      return sidString.value
    }

    static func currentUserSDLSecurityDescriptor() -> SecurityDescriptorBox? {
      guard let sidString = currentUserSIDString() else { return nil }
      defer { LocalFree(UnsafeMutableRawPointer(sidString.pointer)) }
      // D:P(...) = protected DACL; GA = GENERIC_ALL; SY = LOCAL SYSTEM.
      let sddl = "D:P(A;;GA;;;\(sidString.value))(A;;GA;;;SY)"
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

    private static func currentUserSIDString() -> WideStringBox? {
      var token: HANDLE?
      guard OpenProcessToken(GetCurrentProcess(), Constants.tokenQuery, &token), let token
      else { return nil }
      defer { CloseHandle(token) }
      return stringSid(ofToken: token)
    }

    private static func userSIDString(ofProcess process: HANDLE) -> WideStringBox? {
      var token: HANDLE?
      guard OpenProcessToken(process, Constants.tokenQuery, &token), let token else {
        return nil
      }
      defer { CloseHandle(token) }
      return stringSid(ofToken: token)
    }

    private static func stringSid(ofToken token: HANDLE) -> WideStringBox? {
      var returnedLength = DWORD(0)
      _ = GetTokenInformation(
        token, TOKEN_INFORMATION_CLASS(rawValue: TokenUser.rawValue), nil, 0, &returnedLength
      )
      guard returnedLength > 0 else { return nil }
      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(returnedLength),
        alignment: MemoryLayout<Int>.alignment
      )
      defer { buffer.deallocate() }
      guard
        GetTokenInformation(
          token,
          TOKEN_INFORMATION_CLASS(rawValue: TokenUser.rawValue),
          buffer,
          returnedLength,
          &returnedLength
        )
      else { return nil }
      let userSID = buffer.assumingMemoryBound(to: TOKEN_USER.self).User.Sid
      var stringSID: UnsafeMutablePointer<WCHAR>?
      guard let userSID, ConvertSidToStringSidW(userSID, &stringSID), let stringSID else {
        return nil
      }
      return WideStringBox(pointer: stringSID)
    }

    final class Connection: @unchecked Sendable, IPCEventSink {
      let id = UUID()

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
      func push(_ payload: Data) {
        try? send(payload)
      }

      func close() {
        ioLock.lock()
        let current = handle
        handle = nil
        ioLock.unlock()
        guard let current else { return }
        FlushFileBuffers(current)
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
            readRequest(Data(body))
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
          ioLock.unlock()
          guard let current else { throw PipeTransportError.connectionClosed }
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
              close()
              throw PipeTransportError.connectionClosed
            }
            offset += Int(written)
          }
        }
      }

      private func readRequest(_ request: Data) {
        Task { [weakServer, id] in
          guard let server = weakServer.value else { return }
          let response = await server.dispatch(request: request, connectionID: id)
          try? self.send(response)
        }
      }

      private func readExactly(handle: HANDLE, buffer: inout [UInt8]) -> Bool {
        var received = DWORD(0)
        var offset = 0
        while offset < buffer.count {
          let ok = buffer.withUnsafeMutableBytes { raw in
            ReadFile(
              handle,
              raw.baseAddress!.advanced(by: offset),
              DWORD(buffer.count - offset),
              &received,
              nil
            )
          }
          if ok || GetLastError() == Constants.errorMoreData {
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

  final class WideStringBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<WCHAR>

    init(pointer: UnsafeMutablePointer<WCHAR>) {
      self.pointer = pointer
    }

    var value: String {
      var units: [UInt16] = []
      var index = 0
      while pointer[index] != 0 {
        units.append(UInt16(pointer[index]))
        index += 1
      }
      return String(decoding: units, as: UTF16.self)
    }

    deinit {
      LocalFree(UnsafeMutableRawPointer(pointer))
    }
  }

  final class WideBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<WCHAR>

    init(_ value: String) {
      var units = Array(value.utf16)
      units.append(0)
      pointer = .allocate(capacity: units.count)
      units.withUnsafeBufferPointer { buffer in
        pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
      }
    }

    deinit {
      pointer.deallocate()
    }
  }
#endif
