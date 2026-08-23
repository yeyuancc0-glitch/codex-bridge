#if canImport(WinSDK)
  import Foundation
  import WinSDK

  public enum WindowsPrivateBackupProtection {
    public enum ProtectionError: Error, Equatable, Sendable {
      case invalidPath
      case insecurePath
      case systemFailure(Int32)
    }

    private enum Constants {
      static let genericReadWrite = DWORD(0xC000_0000)
      static let errorFileExists = DWORD(80)
      static let errorAlreadyExists = DWORD(183)
      static let protectedDACLInformation = DWORD(0x8000_0004)
    }

    public static func create(at path: String) throws -> Bool {
      try validateParentComponents(path)
      guard let descriptor = securityDescriptor() else {
        throw ProtectionError.systemFailure(Int32(GetLastError()))
      }
      var attributes = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor.pointer,
        bInheritHandle: false
      )
      let wide = WideBuffer(path)
      let handle = CreateFileW(
        wide.pointer,
        Constants.genericReadWrite,
        DWORD(FILE_SHARE_READ),
        &attributes,
        DWORD(CREATE_NEW),
        DWORD(FILE_ATTRIBUTE_NORMAL),
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        let error = GetLastError()
        if error == Constants.errorFileExists || error == Constants.errorAlreadyExists {
          return false
        }
        throw ProtectionError.systemFailure(Int32(error))
      }
      CloseHandle(handle)
      try validate(at: path)
      return true
    }

    public static func protectAndValidate(at path: String) throws {
      guard let descriptor = securityDescriptor() else {
        throw ProtectionError.systemFailure(Int32(GetLastError()))
      }
      var present = WindowsBool(0)
      var defaulted = WindowsBool(0)
      var dacl: PACL?
      guard GetSecurityDescriptorDacl(descriptor.pointer, &present, &dacl, &defaulted),
        present != 0,
        let dacl
      else {
        throw ProtectionError.systemFailure(Int32(GetLastError()))
      }
      let result = SetNamedSecurityInfoW(
        WideBuffer(path).pointer,
        SE_OBJECT_TYPE(rawValue: 1),
        Constants.protectedDACLInformation,
        nil,
        nil,
        dacl,
        nil
      )
      guard result == ERROR_SUCCESS else {
        throw ProtectionError.systemFailure(Int32(result))
      }
      try validate(at: path)
    }

    public static func validate(at path: String) throws {
      try validateParentComponents(path)
      let attributes = GetFileAttributesW(WideBuffer(path).pointer)
      guard attributes != INVALID_FILE_ATTRIBUTES else {
        throw ProtectionError.systemFailure(Int32(GetLastError()))
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        try WindowsServicePaths.hasTrustedProtection(path)
      else {
        throw ProtectionError.insecurePath
      }
    }

    private static func validateParentComponents(_ path: String) throws {
      let normalized = path.replacingOccurrences(of: "/", with: "\\")
      guard isDriveAbsolute(normalized), !normalized.contains("\0") else {
        throw ProtectionError.invalidPath
      }
      var current = String(normalized.prefix(3))
      let components = normalized.dropFirst(3).split(separator: "\\")
      guard components.count >= 2 else { throw ProtectionError.invalidPath }
      for component in components.dropLast() {
        let value = String(component)
        current = current.hasSuffix("\\") ? current + value : current + "\\" + value
        let attributes = GetFileAttributesW(WideBuffer(current).pointer)
        guard attributes != INVALID_FILE_ATTRIBUTES,
          attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
          attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
        else {
          throw ProtectionError.insecurePath
        }
      }
    }

    private static func securityDescriptor() -> SecurityDescriptorBox? {
      guard let sid = WindowsSecurity.currentUserSIDString() else { return nil }
      let sddl = WindowsSecurity.ownerOnlySDDL(userSID: sid.value)
      var descriptor: UnsafeMutableRawPointer?
      guard
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          WideBuffer(sddl).pointer,
          1,
          &descriptor,
          nil
        ), let descriptor
      else { return nil }
      return SecurityDescriptorBox(pointer: descriptor)
    }

    private static func isDriveAbsolute(_ path: String) -> Bool {
      let units = Array(path.utf16)
      guard units.count >= 3, units[1] == 58, units[2] == 92 else { return false }
      return (65...90).contains(Int(units[0])) || (97...122).contains(Int(units[0]))
    }
  }

  private final class SecurityDescriptorBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(pointer: UnsafeMutableRawPointer) {
      self.pointer = pointer
    }

    deinit {
      LocalFree(pointer)
    }
  }
#endif
