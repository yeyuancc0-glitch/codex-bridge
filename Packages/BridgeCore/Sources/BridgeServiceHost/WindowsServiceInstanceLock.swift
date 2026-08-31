#if os(Windows)
  import BridgeIPC
  import Foundation
  import WinSDK

  final class WindowsServiceInstanceLock: @unchecked Sendable {
    private let handle: HANDLE

    init() throws {
      let security = try WindowsNamedPipeSecurity()
      var attributes = security.attributes
      let (created, lastError) = WindowsPipeIdentity.currentMutexName().withCString(
        encodedAs: UTF16.self
      ) {
        name in
        withUnsafeMutablePointer(to: &attributes) { pointer in
          SetLastError(0)
          let handle = CreateMutexW(pointer, false, name)
          return (handle, GetLastError())
        }
      }
      guard let created else {
        throw WindowsServiceInstanceLockError.creationFailed
      }
      guard lastError != ERROR_ALREADY_EXISTS else {
        _ = CloseHandle(created)
        throw WindowsServiceInstanceLockError.alreadyRunning
      }
      guard lastError == 0 else {
        _ = CloseHandle(created)
        throw WindowsServiceInstanceLockError.creationFailed
      }
      self.handle = created
    }

    deinit {
      _ = CloseHandle(handle)
    }
  }

  private enum WindowsServiceInstanceLockError: Error {
    case alreadyRunning
    case creationFailed
  }
#endif
