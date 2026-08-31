#if os(Windows)
  import Foundation
  import WinSDK

  final class WindowsNamedPipeSecurity: @unchecked Sendable {
    let attributes: SECURITY_ATTRIBUTES
    private let descriptor: PSECURITY_DESCRIPTOR

    init() throws {
      let userSID = try Self.currentUserSID()
      let securityDescriptor = try Self.makeDescriptor(for: userSID)
      var attributes = SECURITY_ATTRIBUTES()
      attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      attributes.lpSecurityDescriptor = securityDescriptor
      attributes.bInheritHandle = false
      self.descriptor = securityDescriptor
      self.attributes = attributes
    }

    deinit {
      _ = LocalFree(descriptor)
    }

    private static func currentUserSID() throws -> String {
      var token: HANDLE?
      guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token),
        let token
      else {
        throw WindowsNamedPipeSecurityError.currentUserUnavailable
      }
      defer { _ = CloseHandle(token) }

      var requiredLength: DWORD = 0
      _ = GetTokenInformation(
        token,
        TOKEN_INFORMATION_CLASS.TokenUser,
        nil,
        DWORD(0),
        &requiredLength
      )
      guard requiredLength > 0 else {
        throw WindowsNamedPipeSecurityError.currentUserUnavailable
      }

      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(requiredLength),
        alignment: MemoryLayout<TOKEN_USER>.alignment
      )
      defer { buffer.deallocate() }
      guard
        GetTokenInformation(
          token,
          TOKEN_INFORMATION_CLASS.TokenUser,
          buffer,
          requiredLength,
          &requiredLength
        )
      else {
        throw WindowsNamedPipeSecurityError.currentUserUnavailable
      }

      let tokenUser = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
      guard IsValidSid(tokenUser.User.Sid) else {
        throw WindowsNamedPipeSecurityError.currentUserUnavailable
      }
      var sidString: LPWSTR?
      guard ConvertSidToStringSidW(tokenUser.User.Sid, &sidString), let sidString else {
        throw WindowsNamedPipeSecurityError.currentUserUnavailable
      }
      defer { _ = LocalFree(sidString) }
      return String(decodingCString: sidString, as: UTF16.self)
    }

    private static func makeDescriptor(for userSID: String) throws -> PSECURITY_DESCRIPTOR {
      let sddl = "D:P(A;;GA;;;\(userSID))(A;;GA;;;SY)"
      var descriptor: PSECURITY_DESCRIPTOR?
      let converted = sddl.withCString(encodedAs: UTF16.self) { value in
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          value,
          DWORD(1),
          &descriptor,
          nil
        )
      }
      guard converted, let descriptor else {
        throw WindowsNamedPipeSecurityError.descriptorUnavailable
      }
      return descriptor
    }
  }

  private enum WindowsNamedPipeSecurityError: Error {
    case currentUserUnavailable
    case descriptorUnavailable
  }
#endif
