#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  public enum WindowsSecureRunDirectoryError: Error, Equatable, Sendable {
    case invalidPath
    case networkPathDenied
    case reparsePointDenied
    case unavailable(Int32)
    case insecureDirectory
    case notDirectory
    case notRegularFile
    case invalidEntryName
    case entryAlreadyExists
    case fileTooLarge
  }

  package struct WindowsSecureRunDirectoryIdentity: Equatable, Sendable {
    package let volumeSerialNumber: UInt64
    package let fileID: [UInt8]
  }

  /// A handle-backed, current-user-owned directory for one Tunnel run.
  ///
  /// The object keeps the directory identity captured at open time and only
  /// accepts fixed single-component entry names. All path-based operations
  /// re-check the parent identity and reject reparse points before touching an
  /// entry. This mirrors the macOS dirfd boundary without relying on recursive
  /// pathname deletion.
  public final class WindowsSecureRunDirectory: @unchecked Sendable {
    public let path: String
    private let handle: HANDLE
    private let identity: WindowsSecureRunDirectoryIdentity

    public init(existingRoot: URL) throws {
      let path = try Self.validatedExistingPath(existingRoot)
      let handle = try Self.openDirectory(path: path)
      do {
        try Self.validateDirectory(handle: handle, path: path)
        try Self.validateProtectedDACL(handle: handle)
        self.path = path
        self.handle = handle
        identity = try Self.identity(of: handle)
      } catch {
        CloseHandle(handle)
        throw error
      }
    }

    public init(creating name: String, in parent: WindowsSecureRunDirectory) throws {
      guard Self.isSafeEntryName(name), parent.matchesPath() else {
        throw WindowsSecureRunDirectoryError.invalidEntryName
      }
      let path = Self.join(parent.path, name)
      try Self.createProtectedDirectory(path: path)

      do {
        let handle = try Self.openDirectory(path: path)
        do {
          try Self.validateDirectory(handle: handle, path: path)
          try Self.validateProtectedDACL(handle: handle)
          self.path = path
          self.handle = handle
          identity = try Self.identity(of: handle)
        } catch {
          CloseHandle(handle)
          throw error
        }
      } catch {
        _ = Self.removeDirectory(path: path)
        throw error
      }
    }

    deinit {
      CloseHandle(handle)
    }

    public func matchesPath() -> Bool {
      guard Self.isCurrentDirectory(handle: handle, path: path, expected: identity) else {
        return false
      }
      return (try? Self.validateProtectedDACL(handle: handle)) != nil
    }

    public func contains(
      name: String,
      directory: WindowsSecureRunDirectory
    ) -> Bool {
      guard Self.isSafeEntryName(name), matchesPath(), directory.matchesPath() else {
        return false
      }
      let entryPath = Self.join(path, name)
      guard let entryHandle = try? Self.openDirectory(path: entryPath) else { return false }
      defer { CloseHandle(entryHandle) }
      guard
        (try? Self.validateDirectory(handle: entryHandle, path: entryPath)) != nil,
        let entryIdentity = try? Self.identity(of: entryHandle),
        entryIdentity == directory.identity,
        (try? Self.validateProtectedDACL(handle: entryHandle)) != nil
      else {
        return false
      }
      return true
    }

    public func createDirectory(name: String) throws {
      guard Self.isSafeEntryName(name), matchesPath() else {
        throw WindowsSecureRunDirectoryError.invalidEntryName
      }
      let path = Self.join(self.path, name)
      try Self.createProtectedDirectory(path: path)
      do {
        let directory = try WindowsSecureRunDirectory(existingRoot: URL(fileURLWithPath: path))
        guard contains(name: name, directory: directory) else {
          throw WindowsSecureRunDirectoryError.reparsePointDenied
        }
      } catch {
        _ = Self.removeDirectory(path: path)
        throw error
      }
    }

    public func readRegularFile(name: String, maximumBytes: Int) throws -> Data {
      guard Self.isSafeEntryName(name), maximumBytes > 0, matchesPath() else {
        throw WindowsSecureRunDirectoryError.invalidPath
      }
      let path = Self.join(self.path, name)
      let file = try Self.openFile(path: path)
      defer { CloseHandle(file) }
      try Self.validateRegularFile(handle: file, path: path)

      var standard = FILE_STANDARD_INFO()
      guard
        GetFileInformationByHandleEx(
          file,
          FileStandardInfo,
          &standard,
          DWORD(MemoryLayout<FILE_STANDARD_INFO>.size)
        )
      else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      guard standard.DeletePending == 0, standard.EndOfFile.QuadPart >= 0,
        standard.NumberOfLinks == 1,
        UInt64(standard.EndOfFile.QuadPart) <= UInt64(maximumBytes)
      else {
        throw WindowsSecureRunDirectoryError.fileTooLarge
      }

      var result = Data(capacity: Int(standard.EndOfFile.QuadPart))
      var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
      while result.count < maximumBytes {
        let requested = min(buffer.count, maximumBytes - result.count)
        var count = DWORD(0)
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(file, bytes.baseAddress, DWORD(requested), &count, nil)
        }
        guard succeeded else {
          throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
        }
        if count == 0 { break }
        result.append(contentsOf: buffer.prefix(Int(count)))
      }
      if result.count == maximumBytes {
        var probe: UInt8 = 0
        var count = DWORD(0)
        let succeeded = withUnsafeMutableBytes(of: &probe) { bytes in
          ReadFile(file, bytes.baseAddress, DWORD(1), &count, nil)
        }
        guard succeeded else {
          throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
        }
        guard count == 0 else {
          throw WindowsSecureRunDirectoryError.fileTooLarge
        }
      }
      return result
    }

    public func removeEntry(name: String, directory: Bool = false) throws {
      guard Self.isSafeEntryName(name), matchesPath() else {
        throw WindowsSecureRunDirectoryError.invalidEntryName
      }
      let path = Self.join(self.path, name)
      let attributes = Self.attributes(at: path)
      guard attributes != INVALID_FILE_ATTRIBUTES else {
        let error = GetLastError()
        if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) {
          return
        }
        throw WindowsSecureRunDirectoryError.unavailable(Int32(error))
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsSecureRunDirectoryError.reparsePointDenied
      }
      let isDirectory = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      guard isDirectory == directory else {
        throw directory
          ? WindowsSecureRunDirectoryError.notDirectory
          : WindowsSecureRunDirectoryError.notRegularFile
      }
      let succeeded =
        directory
        ? Self.removeDirectory(path: path)
        : Self.removeFile(path: path)
      guard succeeded else {
        let error = GetLastError()
        if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) {
          return
        }
        throw WindowsSecureRunDirectoryError.unavailable(Int32(error))
      }
    }

    private static func validatedExistingPath(_ url: URL) throws -> String {
      guard url.isFileURL else { throw WindowsSecureRunDirectoryError.invalidPath }
      let path = normalize(url.path)
      guard isLocalAbsolutePath(path) else {
        throw path.hasPrefix("\\\\")
          ? WindowsSecureRunDirectoryError.networkPathDenied
          : WindowsSecureRunDirectoryError.invalidPath
      }
      var current = String(path.prefix(3))
      let components = path.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
      for componentSlice in components {
        let component = String(componentSlice)
        guard isSafeEntryName(component) else {
          throw WindowsSecureRunDirectoryError.invalidPath
        }
        current += component
        let attributes = Self.attributes(at: current)
        guard attributes != INVALID_FILE_ATTRIBUTES else {
          throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
        }
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
          throw WindowsSecureRunDirectoryError.reparsePointDenied
        }
        current += "\\"
      }
      return path
    }

    private static func openDirectory(path: String) throws -> HANDLE {
      let wide = WideBuffer(path)
      let flags = DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
      let handle = CreateFileW(
        wide.pointer,
        DWORD(0x120_089),  // FILE_GENERIC_READ (macro, not exported)
        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
        nil,
        DWORD(OPEN_EXISTING),
        flags,
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      return handle
    }

    private static func openFile(path: String) throws -> HANDLE {
      let wide = WideBuffer(path)
      let handle = CreateFileW(
        wide.pointer,
        DWORD(0x120_089),  // FILE_GENERIC_READ (macro, not exported)
        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      return handle
    }

    private static func validateDirectory(handle: HANDLE, path: String) throws {
      let attributes = try attributes(of: handle)
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsSecureRunDirectoryError.reparsePointDenied
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        throw WindowsSecureRunDirectoryError.notDirectory
      }
      guard equivalent(try finalPath(handle: handle), path) else {
        throw WindowsSecureRunDirectoryError.reparsePointDenied
      }
    }

    private static func validateRegularFile(handle: HANDLE, path: String) throws {
      let attributes = try attributes(of: handle)
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsSecureRunDirectoryError.reparsePointDenied
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        throw WindowsSecureRunDirectoryError.notRegularFile
      }
      guard equivalent(try finalPath(handle: handle), path) else {
        throw WindowsSecureRunDirectoryError.reparsePointDenied
      }
    }

    private static func attributes(of handle: HANDLE) throws -> DWORD {
      var info = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &info,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      return info.FileAttributes
    }

    private static func attributes(at path: String) -> DWORD {
      let wide = WideBuffer(path)
      return GetFileAttributesW(wide.pointer)
    }

    private static func identity(of handle: HANDLE) throws -> WindowsSecureRunDirectoryIdentity {
      var info = FILE_ID_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileIdInfo,
          &info,
          DWORD(MemoryLayout<FILE_ID_INFO>.size)
        )
      else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      let bytes = withUnsafeBytes(of: info.FileId.Identifier) { Array($0) }
      return WindowsSecureRunDirectoryIdentity(
        volumeSerialNumber: info.VolumeSerialNumber,
        fileID: bytes
      )
    }

    private static func isCurrentDirectory(
      handle: HANDLE,
      path: String,
      expected: WindowsSecureRunDirectoryIdentity
    ) -> Bool {
      guard
        (try? validateDirectory(handle: handle, path: path)) != nil,
        let current = try? identity(of: handle),
        current == expected
      else {
        return false
      }
      return true
    }

    private static func finalPath(handle: HANDLE) throws -> String {
      let flags = DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
      let length = GetFinalPathNameByHandleW(handle, nil, 0, flags)
      guard length > 0 else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), flags)
      guard written > 0, written < DWORD(buffer.count) else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      let value = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      return value.hasPrefix("\\\\?\\") ? String(value.dropFirst(4)) : value
    }

    private static func validateProtectedDACL(handle: HANDLE) throws {
      guard let currentUser = WindowsSecurity.currentUserSIDString() else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      var descriptor: UnsafeMutableRawPointer?
      var owner: PSID?
      var dacl: PACL?
      let result = GetSecurityInfo(
        handle,
        SE_OBJECT_TYPE(rawValue: Int32(1)),
        DWORD(0x0000_0001 | 0x0000_0004),  // owner + DACL security information
        &owner,
        nil,
        &dacl,
        nil,
        &descriptor
      )
      guard result == DWORD(ERROR_SUCCESS), let descriptor else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(result))
      }
      defer { LocalFree(descriptor) }

      var daclPresent = WindowsBool(false)
      var daclDefaulted = WindowsBool(false)
      guard GetSecurityDescriptorDacl(descriptor, &daclPresent, &dacl, &daclDefaulted),
        daclPresent.boolValue,
        let dacl
      else {
        throw WindowsSecureRunDirectoryError.insecureDirectory
      }

      var control = SECURITY_DESCRIPTOR_CONTROL()
      var revision = DWORD(0)
      guard GetSecurityDescriptorControl(descriptor, &control, &revision),
        (control & UInt16(0x1000)) != 0  // SE_DACL_PROTECTED
      else {
        throw WindowsSecureRunDirectoryError.insecureDirectory
      }

      var sizeInfo = ACL_SIZE_INFORMATION()
      guard
        GetAclInformation(
          dacl,
          &sizeInfo,
          DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size),
          AclSizeInformation
        )
      else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }

      var hasCurrentUser = false
      var hasSystem = false
      for index in 0..<sizeInfo.AceCount {
        var acePointer: UnsafeMutableRawPointer?
        guard GetAce(dacl, DWORD(index), &acePointer), let acePointer else {
          throw WindowsSecureRunDirectoryError.insecureDirectory
        }
        let header = acePointer.load(as: ACE_HEADER.self)
        guard header.AceType == 0 else {
          throw WindowsSecureRunDirectoryError.insecureDirectory
        }
        let sid = acePointer.advanced(by: 8)
        guard let sidValue = Self.sidString(sid) else {
          throw WindowsSecureRunDirectoryError.insecureDirectory
        }
        guard sidValue == currentUser.value || sidValue == "S-1-5-18" else {
          throw WindowsSecureRunDirectoryError.insecureDirectory
        }
        hasCurrentUser = hasCurrentUser || sidValue == currentUser.value
        hasSystem = hasSystem || sidValue == "S-1-5-18"
      }
      guard hasCurrentUser, hasSystem else {
        throw WindowsSecureRunDirectoryError.insecureDirectory
      }
    }

    private static func sidString(_ sid: PSID) -> String? {
      var pointer: UnsafeMutablePointer<WCHAR>?
      guard ConvertSidToStringSidW(sid, &pointer), let pointer else { return nil }
      defer { LocalFree(UnsafeMutableRawPointer(pointer)) }
      var units: [UInt16] = []
      var index = 0
      while pointer[index] != 0 {
        units.append(UInt16(pointer[index]))
        index += 1
      }
      return String(decoding: units, as: UTF16.self)
    }

    private static func createProtectedDirectory(path: String) throws {
      guard let currentUser = WindowsSecurity.currentUserSIDString() else {
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
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
        throw WindowsSecureRunDirectoryError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(descriptor) }

      var security = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor,
        bInheritHandle: false
      )
      let pathWide = WideBuffer(path)
      guard CreateDirectoryW(pathWide.pointer, &security) else {
        let error = GetLastError()
        if error == DWORD(ERROR_ALREADY_EXISTS) {
          throw WindowsSecureRunDirectoryError.entryAlreadyExists
        }
        throw WindowsSecureRunDirectoryError.unavailable(Int32(error))
      }
    }

    private static func removeDirectory(path: String) -> Bool {
      let wide = WideBuffer(path)
      return RemoveDirectoryW(wide.pointer)
    }

    private static func removeFile(path: String) -> Bool {
      let wide = WideBuffer(path)
      return DeleteFileW(wide.pointer)
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
      WindowsTunnelPathRules.isSafeEntryName(name)
    }

    private static func join(_ parent: String, _ name: String) -> String {
      parent.hasSuffix("\\") ? parent + name : parent + "\\" + name
    }

    private static func normalize(_ value: String) -> String {
      WindowsTunnelPathRules.normalize(value)
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
      normalize(lhs).caseInsensitiveCompare(normalize(rhs)) == .orderedSame
    }

    private static func isLocalAbsolutePath(_ path: String) -> Bool {
      WindowsTunnelPathRules.isLocalAbsolutePath(path)
    }
  }
#endif
