#if canImport(WinSDK)
  import Foundation
  import WinSDK

  final class WindowsSecurityHandle: @unchecked Sendable {
    let value: HANDLE
    private let lock = NSLock()
    private var closed = false

    init(_ value: HANDLE) {
      self.value = value
    }

    deinit {
      close()
    }

    func close() {
      lock.lock()
      guard !closed else {
        lock.unlock()
        return
      }
      closed = true
      lock.unlock()
      CloseHandle(value)
    }
  }

  struct WindowsFileSnapshot: Equatable, Sendable {
    let identity: FileSystemIdentity
    let byteCount: Int
    let linkCount: UInt32
  }

  final class WindowsDirectoryLease: @unchecked Sendable {
    let path: String
    let leaf: WindowsSecurityHandle
    private let handles: [WindowsSecurityHandle]

    init(path: String, handles: [WindowsSecurityHandle]) {
      self.path = path
      self.handles = handles
      leaf = handles[handles.count - 1]
    }
  }

  enum WindowsSecureMutationSupport {
    static let genericRead = DWORD(0x8000_0000)
    static let genericWrite = DWORD(0x4000_0000)
    static let defaultShare = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE)

    static func parentLease(
      relativePath: SecureRelativePath,
      root: RegisteredRoot,
      createParents: Bool
    ) throws -> (WindowsDirectoryLease, String) {
      try WindowsSecurePathRules.validate(relativePath)
      guard let name = relativePath.components.last else {
        throw PathSecurityError.invalidRelativePath("empty path")
      }
      let lease = try directoryLease(
        components: Array(relativePath.components.dropLast()),
        root: root,
        createMissing: createParents
      )
      return (lease, name)
    }

    static func directoryLease(
      components: [String],
      root: RegisteredRoot,
      createMissing: Bool
    ) throws -> WindowsDirectoryLease {
      if !components.isEmpty {
        try WindowsSecurePathRules.validate(components: components)
      }
      var handles: [WindowsSecurityHandle] = []
      var currentPath = normalize(root.canonicalPath)
      let rootHandle = try openDirectory(path: currentPath)
      try validateDirectory(
        handle: rootHandle.value,
        expectedPath: currentPath,
        root: root,
        requireRootIdentity: true
      )
      handles.append(rootHandle)

      for component in components {
        currentPath = join(currentPath, component)
        var next = try optionalDirectory(path: currentPath)
        if next == nil, createMissing {
          try createDirectory(path: currentPath, allowExisting: true)
          next = try optionalDirectory(path: currentPath)
        }
        guard let next else { throw PathSecurityError.pathDoesNotExist }
        try validateDirectory(
          handle: next.value,
          expectedPath: currentPath,
          root: root,
          requireRootIdentity: false
        )
        handles.append(next)
      }
      return WindowsDirectoryLease(path: currentPath, handles: handles)
    }

    static func join(_ parent: String, _ name: String) -> String {
      normalize(parent) + "\\" + name
    }

    static func createStagingFile(
      parentPath: String,
      root: RegisteredRoot
    ) throws -> (path: String, handle: WindowsSecurityHandle) {
      for _ in 0..<8 {
        let name = ".codexbridge.staging.\(UUID().uuidString.lowercased())"
        let path = join(parentPath, name)
        do {
          let handle = try openFile(
            path: path,
            access: genericRead | genericWrite,
            share: defaultShare,
            disposition: DWORD(CREATE_NEW),
            flags: DWORD(
              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH
            )
          )
          let snapshot = try validateRegularFile(
            handle: handle.value,
            expectedPath: path,
            root: root
          )
          guard snapshot.linkCount <= 1 else {
            throw PathSecurityError.unsupportedHardLink
          }
          return (path, handle)
        } catch PathSecurityError.targetAlreadyExists {
          continue
        }
      }
      throw PathSecurityError.writeFailed(Int32(ERROR_ALREADY_EXISTS))
    }

    static func optionalRegularFile(
      path: String,
      root: RegisteredRoot,
      access: DWORD = genericRead,
      share: DWORD = defaultShare
    ) throws -> WindowsSecurityHandle? {
      guard
        let handle = try optionalFile(
          path: path,
          access: access,
          share: share,
          flags: DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        )
      else { return nil }
      do {
        _ = try validateRegularFile(handle: handle.value, expectedPath: path, root: root)
        return handle
      } catch {
        handle.close()
        throw error
      }
    }

    static func readRegularFile(
      path: String,
      root: RegisteredRoot,
      maximumBytes: Int,
      requireSingleLink: Bool
    ) throws -> (data: Data, snapshot: WindowsFileSnapshot) {
      guard let handle = try optionalRegularFile(path: path, root: root) else {
        throw PathSecurityError.pathDoesNotExist
      }
      defer { handle.close() }
      let snapshot = try validateRegularFile(
        handle: handle.value,
        expectedPath: path,
        root: root
      )
      if requireSingleLink, snapshot.linkCount > 1 {
        throw PathSecurityError.unsupportedHardLink
      }
      guard snapshot.byteCount <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }
      return (
        try readAll(handle: handle.value, maximumBytes: maximumBytes),
        snapshot
      )
    }

    static func validateRegularFile(
      handle: HANDLE,
      expectedPath: String,
      root: RegisteredRoot
    ) throws -> WindowsFileSnapshot {
      let attributes = try attributes(of: handle)
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw PathSecurityError.pathEscapeBlocked
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        throw PathSecurityError.targetNotRegularFile
      }
      let identity = try identity(of: handle)
      guard identity.volumeID == root.identity.volumeID else {
        throw PathSecurityError.pathEscapeBlocked
      }
      guard equivalent(try finalPath(handle: handle), expectedPath) else {
        throw PathSecurityError.pathChanged
      }

      var standard = FILE_STANDARD_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileStandardInfo,
          &standard,
          DWORD(MemoryLayout<FILE_STANDARD_INFO>.size)
        )
      else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      guard standard.DeletePending == 0, standard.EndOfFile.QuadPart >= 0,
        UInt64(standard.EndOfFile.QuadPart) <= UInt64(Int.max)
      else {
        throw PathSecurityError.pathChanged
      }
      return WindowsFileSnapshot(
        identity: identity,
        byteCount: Int(standard.EndOfFile.QuadPart),
        linkCount: UInt32(standard.NumberOfLinks)
      )
    }

    static func writeAll(handle: HANDLE, data: Data) throws {
      var offset = 0
      while offset < data.count {
        var written = DWORD(0)
        let succeeded = data.withUnsafeBytes { bytes in
          WriteFile(
            handle,
            bytes.baseAddress!.advanced(by: offset),
            DWORD(data.count - offset),
            &written,
            nil
          )
        }
        guard succeeded, written > 0 else {
          throw PathSecurityError.writeFailed(Int32(GetLastError()))
        }
        offset += Int(written)
      }
    }

    static func flush(handle: HANDLE) throws {
      guard FlushFileBuffers(handle) else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func readAll(handle: HANDLE, maximumBytes: Int) throws -> Data {
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
      while result.count <= maximumBytes {
        let requested = min(buffer.count, maximumBytes + 1 - result.count)
        var readBytes = DWORD(0)
        guard ReadFile(handle, &buffer, DWORD(requested), &readBytes, nil) else {
          throw PathSecurityError.readFailed(Int32(GetLastError()))
        }
        if readBytes == 0 { return result }
        result.append(contentsOf: buffer.prefix(Int(readBytes)))
      }
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }

    static func move(
      sourcePath: String,
      destinationPath: String,
      replaceExisting: Bool
    ) throws {
      var flags = DWORD(MOVEFILE_WRITE_THROUGH)
      if replaceExisting { flags |= DWORD(MOVEFILE_REPLACE_EXISTING) }
      let succeeded = withWide(sourcePath) { source in
        withWide(destinationPath) { destination in
          MoveFileExW(source, destination, flags)
        }
      }
      guard succeeded else {
        let code = GetLastError()
        if code == ERROR_ALREADY_EXISTS || code == ERROR_FILE_EXISTS {
          throw PathSecurityError.targetAlreadyExists
        }
        throw PathSecurityError.writeFailed(Int32(code))
      }
    }

    static func deleteFile(path: String) throws {
      let succeeded = withWide(path) { DeleteFileW($0) }
      guard succeeded else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func removeDirectory(path: String) throws {
      let succeeded = withWide(path) { RemoveDirectoryW($0) }
      guard succeeded else {
        let code = GetLastError()
        if code == ERROR_DIR_NOT_EMPTY { throw PathSecurityError.unsupportedFileType }
        throw PathSecurityError.writeFailed(Int32(code))
      }
    }

    static func createDirectory(path: String, allowExisting: Bool) throws {
      let succeeded = withWide(path) { CreateDirectoryW($0, nil) }
      guard succeeded else {
        let code = GetLastError()
        if code == ERROR_ALREADY_EXISTS {
          if allowExisting { return }
          throw PathSecurityError.targetAlreadyExists
        }
        throw PathSecurityError.writeFailed(Int32(code))
      }
    }

    static func cleanupFile(path: String) {
      _ = withWide(path) { DeleteFileW($0) }
    }

    static func fileIdentity(path: String, root: RegisteredRoot) throws -> FileSystemIdentity? {
      guard let handle = try optionalRegularFile(path: path, root: root) else { return nil }
      defer { handle.close() }
      return try validateRegularFile(handle: handle.value, expectedPath: path, root: root).identity
    }

    static func directoryIdentity(
      components: [String],
      root: RegisteredRoot
    ) throws -> FileSystemIdentity {
      let lease = try directoryLease(
        components: components,
        root: root,
        createMissing: false
      )
      return try identity(of: lease.leaf.value)
    }

    private static func openDirectory(path: String) throws -> WindowsSecurityHandle {
      guard
        let handle = try optionalFile(
          path: path,
          access: DWORD(0),
          share: defaultShare,
          flags: DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        )
      else { throw PathSecurityError.pathDoesNotExist }
      return handle
    }

    private static func optionalDirectory(path: String) throws -> WindowsSecurityHandle? {
      try optionalFile(
        path: path,
        access: DWORD(0),
        share: defaultShare,
        flags: DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
      )
    }

    private static func openFile(
      path: String,
      access: DWORD,
      share: DWORD,
      disposition: DWORD,
      flags: DWORD
    ) throws -> WindowsSecurityHandle {
      let raw = withWide(path) { wide in
        CreateFileW(wide, access, share, nil, disposition, flags, nil)
      }
      guard let raw, raw != INVALID_HANDLE_VALUE else {
        let code = GetLastError()
        if code == ERROR_ALREADY_EXISTS || code == ERROR_FILE_EXISTS {
          throw PathSecurityError.targetAlreadyExists
        }
        throw PathSecurityError.writeFailed(Int32(code))
      }
      return WindowsSecurityHandle(raw)
    }

    private static func optionalFile(
      path: String,
      access: DWORD,
      share: DWORD,
      flags: DWORD
    ) throws -> WindowsSecurityHandle? {
      let raw = withWide(path) { wide in
        CreateFileW(wide, access, share, nil, DWORD(OPEN_EXISTING), flags, nil)
      }
      guard let raw, raw != INVALID_HANDLE_VALUE else {
        let code = GetLastError()
        if code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND { return nil }
        throw PathSecurityError.readFailed(Int32(code))
      }
      return WindowsSecurityHandle(raw)
    }

    private static func validateDirectory(
      handle: HANDLE,
      expectedPath: String,
      root: RegisteredRoot,
      requireRootIdentity: Bool
    ) throws {
      let attributes = try attributes(of: handle)
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw PathSecurityError.pathEscapeBlocked
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
        throw PathSecurityError.unsupportedFileType
      }
      let identity = try identity(of: handle)
      if requireRootIdentity {
        guard identity == root.identity else { throw PathSecurityError.rootIdentityChanged }
      } else {
        guard identity.volumeID == root.identity.volumeID else {
          throw PathSecurityError.pathEscapeBlocked
        }
      }
      guard equivalent(try finalPath(handle: handle), expectedPath) else {
        throw PathSecurityError.pathChanged
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
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      return info.FileAttributes
    }

    static func identity(of handle: HANDLE) throws -> FileSystemIdentity {
      var info = FILE_ID_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileIdInfo,
          &info,
          DWORD(MemoryLayout<FILE_ID_INFO>.size)
        )
      else {
        throw PathSecurityError.readFailed(Int32(GetLastError()))
      }
      let fileID = withUnsafeBytes(of: info.FileId.Identifier) { bytes in
        bytes.map { String(format: "%02x", $0) }.joined()
      }
      return try FileSystemIdentity(
        kind: FileSystemIdentity.windowsFileID128Kind,
        volumeID: String(info.VolumeSerialNumber),
        fileID: fileID
      )
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
      return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
    }

    private static func normalize(_ path: String) -> String {
      var value = path.replacingOccurrences(of: "/", with: "\\")
      if value.hasPrefix("\\\\?\\") { value = String(value.dropFirst(4)) }
      while value.count > 3, value.hasSuffix("\\") { value.removeLast() }
      return value
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
      normalize(lhs).caseInsensitiveCompare(normalize(rhs)) == .orderedSame
    }

    private static func apiPath(_ path: String) -> String {
      let normalized = normalize(path)
      if normalized.hasPrefix("\\\\") || normalized.hasPrefix("\\\\?\\") {
        return normalized
      }
      return "\\\\?\\" + normalized
    }

    private static func withWide<Result>(
      _ path: String,
      _ body: (UnsafePointer<WCHAR>) -> Result
    ) -> Result {
      var wide = Array(apiPath(path).utf16)
      wide.append(0)
      return wide.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress!)
      }
    }
  }
#endif
