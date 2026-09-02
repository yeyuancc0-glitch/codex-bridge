#if os(Windows)
  import Foundation
  import WinSDK

  final class NamedPipeOverlappedIO: @unchecked Sendable {
    let readComplete: HANDLE
    let writeComplete: HANDLE
    let cancel: HANDLE
    let readerExited: HANDLE

    init?() {
      guard let readComplete = CreateEventW(nil, true, false, nil) else { return nil }
      guard let writeComplete = CreateEventW(nil, true, false, nil) else {
        _ = CloseHandle(readComplete)
        return nil
      }
      guard let cancel = CreateEventW(nil, true, false, nil) else {
        _ = CloseHandle(readComplete)
        _ = CloseHandle(writeComplete)
        return nil
      }
      guard let readerExited = CreateEventW(nil, true, true, nil) else {
        _ = CloseHandle(readComplete)
        _ = CloseHandle(writeComplete)
        _ = CloseHandle(cancel)
        return nil
      }
      self.readComplete = readComplete
      self.writeComplete = writeComplete
      self.cancel = cancel
      self.readerExited = readerExited
    }

    deinit {
      _ = CloseHandle(readComplete)
      _ = CloseHandle(writeComplete)
      _ = CloseHandle(cancel)
      _ = CloseHandle(readerExited)
    }

    func prepareConnection() {
      _ = ResetEvent(readComplete)
      _ = ResetEvent(writeComplete)
      _ = ResetEvent(cancel)
      _ = ResetEvent(readerExited)
    }

    func requestCancellation() {
      _ = SetEvent(cancel)
    }

    func signalReaderExited() {
      _ = SetEvent(readerExited)
    }

    func waitForReaderExit() {
      _ = WaitForSingleObject(readerExited, 5_000)
    }

    func readFully(_ handle: HANDLE, count: UInt32) -> Data? {
      guard count > 0 else { return Data() }
      var buffer = Data(count: Int(count))
      let completed = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let baseAddress = raw.baseAddress else { return false }
        var total: UInt32 = 0
        while total < count {
          guard
            let read = readChunk(
              handle,
              into: baseAddress.advanced(by: Int(total)),
              count: count - total
            )
          else { return false }
          total += read
        }
        return true
      }
      return completed ? buffer : nil
    }

    func writeFully(_ handle: HANDLE, data: Data) throws {
      try data.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
          let written = try writeChunk(
            handle,
            from: baseAddress.advanced(by: offset),
            count: DWORD(raw.count - offset)
          )
          guard written > 0 else { throw BridgeServiceClientError.unavailable }
          offset += Int(written)
        }
      }
    }

    private func readChunk(
      _ handle: HANDLE,
      into buffer: UnsafeMutableRawPointer,
      count: DWORD
    ) -> DWORD? {
      _ = ResetEvent(readComplete)
      var overlapped = OVERLAPPED()
      overlapped.hEvent = readComplete
      let immediate = ReadFile(handle, buffer, count, nil, &overlapped)
      return waitForTransfer(
        handle,
        overlapped: &overlapped,
        completeEvent: readComplete,
        immediate: immediate
      )
    }

    private func writeChunk(
      _ handle: HANDLE,
      from buffer: UnsafeRawPointer,
      count: DWORD
    ) throws -> DWORD {
      _ = ResetEvent(writeComplete)
      var overlapped = OVERLAPPED()
      overlapped.hEvent = writeComplete
      let immediate = WriteFile(handle, buffer, count, nil, &overlapped)
      guard
        let written = waitForTransfer(
          handle,
          overlapped: &overlapped,
          completeEvent: writeComplete,
          immediate: immediate
        )
      else { throw BridgeServiceClientError.unavailable }
      return written
    }

    private func waitForTransfer(
      _ handle: HANDLE,
      overlapped: inout OVERLAPPED,
      completeEvent: HANDLE,
      immediate: Bool
    ) -> DWORD? {
      if !immediate, GetLastError() != ERROR_IO_PENDING { return nil }
      if !immediate {
        var waitHandles: [HANDLE?] = [completeEvent, cancel]
        let result = waitHandles.withUnsafeMutableBufferPointer { handles in
          WaitForMultipleObjects(DWORD(handles.count), handles.baseAddress, false, INFINITE)
        }
        guard result == WAIT_OBJECT_0 else {
          _ = CancelIoEx(handle, &overlapped)
          var cancelledBytes: DWORD = 0
          _ = GetOverlappedResult(handle, &overlapped, &cancelledBytes, true)
          return nil
        }
      }
      var transferred: DWORD = 0
      guard GetOverlappedResult(handle, &overlapped, &transferred, false), transferred > 0 else {
        return nil
      }
      return transferred
    }
  }
#endif
