#if os(Windows)
  import BridgeIPC
  import Foundation
  import WinSDK

  enum WindowsServiceShutdown {
    private static let retryCount = 50
    private static let retryDelayNanoseconds: UInt64 = 100_000_000

    static func requestAndWait() async throws {
      let expectedPath = try WindowsProcessIdentity.currentImagePath()
      for attempt in 0..<retryCount {
        let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
        do {
          let response = try await client.shutdownService()
          await client.invalidate()
          try wait(for: response, expectedPath: expectedPath)
          return
        } catch let error as BridgeServiceClientError {
          await client.invalidate()
          guard case .unavailable = error else { throw error }
          guard try WindowsProcessIdentity.hasOtherProcess(at: expectedPath) else { return }
          guard attempt + 1 < retryCount else {
            throw WindowsServiceShutdownError.serviceUnavailable
          }
          try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        } catch {
          await client.invalidate()
          throw error
        }
      }
    }

    private static func wait(
      for response: IPCServiceShutdownResponse,
      expectedPath: String
    ) throws {
      guard response.processID > 0,
        response.processID != GetCurrentProcessId(),
        WindowsProcessIdentity.pathsEqual(response.imagePath, expectedPath)
      else { throw WindowsServiceShutdownError.invalidProcessIdentity }
      guard
        let handle = OpenProcess(
          DWORD(SYNCHRONIZE) | DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
          false,
          DWORD(response.processID)
        )
      else {
        if GetLastError() == ERROR_INVALID_PARAMETER {
          guard try !WindowsProcessIdentity.hasOtherProcess(at: expectedPath) else {
            throw WindowsServiceShutdownError.invalidProcessIdentity
          }
          return
        }
        throw WindowsServiceShutdownError.openProcessFailed
      }
      defer { _ = CloseHandle(handle) }
      guard let actualPath = WindowsProcessIdentity.imagePath(for: handle),
        WindowsProcessIdentity.pathsEqual(actualPath, expectedPath)
      else { throw WindowsServiceShutdownError.invalidProcessIdentity }
      let waitResult = WaitForSingleObject(handle, 30_000)
      if waitResult == WAIT_OBJECT_0 { return }
      if waitResult == DWORD(WAIT_TIMEOUT) {
        throw WindowsServiceShutdownError.timeout
      }
      throw WindowsServiceShutdownError.waitFailed
    }
  }

  private enum WindowsServiceShutdownError: Error {
    case invalidProcessIdentity
    case openProcessFailed
    case serviceUnavailable
    case timeout
    case waitFailed
  }
#endif
