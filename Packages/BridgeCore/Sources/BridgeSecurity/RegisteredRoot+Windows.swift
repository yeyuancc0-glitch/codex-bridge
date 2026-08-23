#if canImport(WinSDK)
  import Foundation
  import WinSDK

  // Windows root capture: open the directory through a HANDLE, reject reparse
  // points, and record the authoritative FILE_ID_INFO identity. Security
  // judgments never rely on the display path string.
  public struct RegisteredRoot: Codable, Equatable, Sendable {
    public let canonicalPath: String
    public let identity: FileSystemIdentity

    public init(capturing url: URL) throws {
      let rawPath = url.path
      // Network UNC roots fail closed until a real remote security model exists.
      guard !rawPath.hasPrefix("\\\\"), !rawPath.hasPrefix("//") else {
        throw PathSecurityError.rootUnavailable
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw PathSecurityError.rootUnavailable
      }

      let handle = try Self.openDirectory(path: rawPath)
      defer { CloseHandle(handle) }

      let finalPath = try Self.finalPath(handle: handle)
      guard !finalPath.hasPrefix("\\\\") else {
        throw PathSecurityError.rootUnavailable
      }
      canonicalPath = finalPath
      identity = try Self.identity(handle: handle)
    }

    public func validateCurrentIdentity() throws {
      guard FileManager.default.fileExists(atPath: canonicalPath) else {
        throw PathSecurityError.rootUnavailable
      }
      guard
        try RegisteredRoot(
          capturing: URL(fileURLWithPath: canonicalPath, isDirectory: true)
        ) == self
      else {
        throw PathSecurityError.rootIdentityChanged
      }
    }

    /// Identity re-capture used by ProjectPathResolver after path validation.
    static func readIdentity(atPath path: String) throws -> FileSystemIdentity {
      let handle = try openExisting(path: path)
      defer { CloseHandle(handle) }
      return try identity(handle: handle)
    }

    private static func openDirectory(path: String) throws -> HANDLE {
      try openExisting(path: path)
    }

    private static func openExisting(path: String) throws -> HANDLE {
      var wide = Array(path.utf16)
      wide.append(0)
      let handle = wide.withUnsafeBufferPointer { buffer in
        CreateFileW(
          buffer.baseAddress,
          DWORD(0),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      return handle
    }

    private static func finalPath(handle: HANDLE) throws -> String {
      let flags = DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
      let length = GetFinalPathNameByHandleW(handle, nil, 0, flags)
      guard length > 0 else { throw PathSecurityError.readFailed(Int32(GetLastError())) }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), flags)
      guard written > 0, written < DWORD(buffer.count) else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      let value = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      if value.hasPrefix("\\\\?\\UNC\\") {
        return "\\\\" + String(value.dropFirst(8))
      }
      if value.hasPrefix("\\\\?\\") {
        return String(value.dropFirst(4))
      }
      return value
    }

    private static func identity(handle: HANDLE) throws -> FileSystemIdentity {
      var tagInfo = FILE_ATTRIBUTE_TAG_INFO()
      let tagOK = GetFileInformationByHandleEx(
        handle,
        FileAttributeTagInfo,
        &tagInfo,
        DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
      )
      guard tagOK else { throw PathSecurityError.readFailed(Int32(GetLastError())) }
      guard tagInfo.FileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw PathSecurityError.pathEscapeBlocked
      }

      var info = FILE_ID_INFO()
      let idOK = GetFileInformationByHandleEx(
        handle,
        FileIdInfo,
        &info,
        DWORD(MemoryLayout<FILE_ID_INFO>.size)
      )
      guard idOK else { throw PathSecurityError.readFailed(Int32(GetLastError())) }

      let volume = String(info.VolumeSerialNumber)
      let fileID = withUnsafeBytes(of: info.FileId.Identifier) { bytes in
        bytes.map { String(format: "%02x", $0) }.joined()
      }
      return try FileSystemIdentity(
        kind: FileSystemIdentity.windowsFileID128Kind,
        volumeID: volume,
        fileID: fileID
      )
    }
  }
#endif
