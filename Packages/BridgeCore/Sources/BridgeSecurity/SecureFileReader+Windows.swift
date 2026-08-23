#if canImport(WinSDK)
  import Crypto
  import Foundation
  import WinSDK

  /// Windows twin of the macOS secure reader: every path component is opened
  /// with reparse-point inspection before descending, and the final handle must
  /// reproduce the identity recorded at resolution time.
  public struct SecureFileReader: Sendable {
    public let maximumBytes: Int
    public let maximumLines: Int

    public init(maximumBytes: Int = 200 * 1024, maximumLines: Int = 300) {
      self.maximumBytes = maximumBytes
      self.maximumLines = maximumLines
    }

    public func read(
      _ relativePath: SecureRelativePath,
      through resolver: ProjectPathResolver
    ) throws -> SecureTextFile {
      let resolved = try resolver.resolve(relativePath)
      return try readResolved(resolved, root: resolver.root)
    }

    func readResolved(
      _ resolved: ResolvedProjectPath,
      root: RegisteredRoot
    ) throws -> SecureTextFile {
      let handle = try Self.openVerified(resolved: resolved, root: root)
      defer { CloseHandle(handle) }

      var size = LARGE_INTEGER()
      guard GetFileSizeEx(handle, &size) else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      guard size.QuadPart >= 0, UInt64(size.QuadPart) <= UInt64(Int.max) else {
        throw PathSecurityError.readFailed(ERROR_FILE_INVALID)
      }
      let byteCount = Int(size.QuadPart)
      guard byteCount <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }

      let data = try Self.readAll(handle: handle, capacity: max(byteCount, 1))
      guard !data.contains(0) else { throw PathSecurityError.binaryFileBlocked }
      guard let text = String(data: data, encoding: .utf8) else {
        throw PathSecurityError.binaryFileBlocked
      }

      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      let visible = lines.prefix(maximumLines)
      return SecureTextFile(
        text: visible.joined(separator: "\n"),
        bytesRead: data.count,
        lineCount: visible.count,
        truncated: lines.count > maximumLines,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        byteCount: data.count
      )
    }

    private static func openVerified(
      resolved: ResolvedProjectPath,
      root: RegisteredRoot
    ) throws -> HANDLE {
      let components = try Self.relativeComponents(
        fullPath: resolved.canonicalURL.path,
        base: root.canonicalPath
      )

      var current = root.canonicalPath
      for (index, component) in components.enumerated() {
        current = current + "\\" + component
        let isLast = index == components.count - 1
        let handle = try openNoReparse(path: current)
        defer { CloseHandle(handle) }

        let attributes = try attributes(of: handle)
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
          throw PathSecurityError.pathEscapeBlocked
        }
        if !isLast {
          guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
            throw PathSecurityError.readFailed(ERROR_NOT_READY)
          }
          continue
        }

        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else {
          throw PathSecurityError.unsupportedFileType
        }
        let identity = try WindowsSecureMutationSupport.identity(of: handle)
        guard identity.volumeID == root.identity.volumeID else {
          throw PathSecurityError.pathEscapeBlocked
        }
        guard identity == resolved.identity else {
          throw PathSecurityError.fileIdentityChanged
        }

        let reopened = try reopenForRead(path: current)
        do {
          let reopenedAttributes = try Self.attributes(of: reopened)
          guard reopenedAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
            reopenedAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
          else {
            throw PathSecurityError.pathEscapeBlocked
          }
          guard try WindowsSecureMutationSupport.identity(of: reopened) == resolved.identity else {
            throw PathSecurityError.fileIdentityChanged
          }
          return reopened
        } catch {
          CloseHandle(reopened)
          throw error
        }
      }
      throw PathSecurityError.pathDoesNotExist
    }

    private static func openNoReparse(path: String) throws -> HANDLE {
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

    private static func reopenForRead(path: String) throws -> HANDLE {
      var wide = Array(path.utf16)
      wide.append(0)
      let handle = wide.withUnsafeBufferPointer { buffer in
        CreateFileW(
          buffer.baseAddress,
          DWORD(0x120_089),  // FILE_GENERIC_READ (macro, not exported)
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      return handle
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
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      return info.FileAttributes
    }

    private static func readAll(handle: HANDLE, capacity: Int) throws -> Data {
      var data = Data(capacity: capacity)
      var chunk = [UInt8](repeating: 0, count: 65_536)
      while true {
        var readBytes: DWORD = 0
        guard ReadFile(handle, &chunk, DWORD(chunk.count), &readBytes, nil) else {
          throw PathSecurityError.readFailed(Int32(GetLastError()))
        }
        guard readBytes > 0 else { break }
        data.append(contentsOf: chunk[0..<Int(readBytes)])
        guard data.count <= 32 * 1_024 * 1_024 else {
          throw PathSecurityError.fileTooLarge(maximumBytes: 32 * 1_024 * 1_024)
        }
      }
      return data
    }

    private static func relativeComponents(fullPath: String, base: String) throws -> [String] {
      let normalizedFull = windowsNormalized(fullPath)
      let normalizedBase = windowsNormalized(base)
      guard
        let prefix = normalizedFull.range(
          of: normalizedBase + "\\",
          options: [.anchored, .caseInsensitive]
        )
      else {
        throw PathSecurityError.invalidRelativePath("resolved outside registered root")
      }
      let rest = normalizedFull[prefix.upperBound...]
      guard !rest.isEmpty else {
        throw PathSecurityError.invalidRelativePath("empty")
      }
      let parts = rest.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
      try WindowsSecurePathRules.validate(components: parts)
      return parts
    }

    private static func windowsNormalized(_ path: String) -> String {
      var value = path.replacingOccurrences(of: "/", with: "\\")
      if value.hasPrefix("\\\\?\\") { value = String(value.dropFirst(4)) }
      if value.count >= 4, value.hasPrefix("\\"),
        value[value.index(after: value.startIndex)].isLetter,
        value[value.index(value.startIndex, offsetBy: 2)] == ":"
      {
        value.removeFirst()
      }
      while value.count > 3, value.hasSuffix("\\") { value.removeLast() }
      return value
    }
  }
#endif
