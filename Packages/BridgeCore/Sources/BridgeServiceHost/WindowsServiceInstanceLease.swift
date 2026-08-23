#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  public enum WindowsServiceInstanceLeaseError: Error, Equatable, Sendable {
    case alreadyRunning
    case unavailable(Int32)
  }

  /// Keeps one background Service Host per interactive user session.
  public final class WindowsServiceInstanceLease: @unchecked Sendable {
    private let handle: HANDLE

    public init() throws {
      guard let currentUser = WindowsSecurity.currentUserSIDString() else {
        throw WindowsServiceInstanceLeaseError.unavailable(Int32(GetLastError()))
      }
      let descriptorText = WindowsSecurity.ownerOnlySDDL(userSID: currentUser.value)
      let descriptorWide = WideBuffer(descriptorText)
      var descriptor: UnsafeMutableRawPointer?
      guard
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          descriptorWide.pointer,
          DWORD(1),
          &descriptor,
          nil
        ), let descriptor
      else {
        throw WindowsServiceInstanceLeaseError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(descriptor) }

      var security = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor,
        bInheritHandle: false
      )
      let name = WideBuffer("Local\\org.codexbridge.service")
      guard let mutex = CreateMutexW(&security, false, name.pointer) else {
        throw WindowsServiceInstanceLeaseError.unavailable(Int32(GetLastError()))
      }
      guard GetLastError() != DWORD(ERROR_ALREADY_EXISTS) else {
        CloseHandle(mutex)
        throw WindowsServiceInstanceLeaseError.alreadyRunning
      }
      handle = mutex
    }

    deinit {
      CloseHandle(handle)
    }
  }
#endif
