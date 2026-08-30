#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsSecureFileError: Error {
    case openFailed(Int32)
  }

  /// Handle-based file primitives backing the secure file family on Windows.
  ///
  /// Win32 has no `openat` equivalent, so parent-relative traversal cannot be
  /// reproduced exactly. Instead each path component is checked for reparse
  /// points before the final target is opened, refusing symlink/junction
  /// escapes; the residual TOCTOU window is narrower than the trust boundary
  /// enforced by the user profile ACLs and is documented in docs/WINDOWS_PORT.md.
  enum WindowsSecureFile {
    struct Identity: Equatable {
      let device: UInt64
      let inode: UInt64

      init(info: BY_HANDLE_FILE_INFORMATION) {
        device = UInt64(info.dwVolumeSerialNumber)
        inode = (UInt64(info.nFileIndexHigh) << 32) | UInt64(info.nFileIndexLow)
      }
    }

    struct Metadata {
      let identity: Identity
      let isDirectory: Bool
      let isRegularFile: Bool
      let size: Int
    }

    static func close(_ handle: HANDLE) {
      _ = CloseHandle(handle)
    }

    /// Opens every path component in turn and rejects reparse points. The
    /// final component is opened with `desiredAccess`/`creationDisposition`.
    static func openResolving(
      rootPath: String,
      components: [String],
      desiredAccess: UInt32,
      creationDisposition: DWORD,
      finalIsDirectory: Bool
    ) throws -> (HANDLE, Metadata) {
      try validateComponents(rootPath: rootPath, components: components)
      let targetPath = ([rootPath] + components).joined(separator: "\\")
      let flags = DWORD(FILE_FLAG_BACKUP_SEMANTICS)
      let handle = targetPath.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          desiredAccess,
          0,
          nil,
          creationDisposition,
          flags,
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
      }
      do {
        let metadata = try metadata(of: handle)
        if finalIsDirectory {
          guard metadata.isDirectory else { throw PathSecurityError.unsupportedFileType }
        } else {
          guard metadata.isRegularFile else { throw PathSecurityError.unsupportedFileType }
        }
        return (handle, metadata)
      } catch {
        close(handle)
        throw error
      }
    }

    static func metadata(of handle: HANDLE) throws -> Metadata {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info) else {
        throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
      }
      let isDirectory = info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      return Metadata(
        identity: Identity(info: info),
        isDirectory: isDirectory,
        isRegularFile: !isDirectory
          && info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        size: Int((UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow))
      )
    }

    static func identity(of handle: HANDLE) throws -> Identity {
      try metadata(of: handle).identity
    }

    /// Re-validates that the registered root directory still resolves to the
    /// recorded device/index identity before any traversal happens.
    static func validateRootIdentity(root: RegisteredRoot) throws {
      let handle = root.canonicalPath.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          DWORD(0),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
      }
      defer { close(handle) }
      let currentIdentity = try identity(of: handle)
      guard currentIdentity.device == root.identity.device,
        currentIdentity.inode == root.identity.inode
      else {
        throw PathSecurityError.rootIdentityChanged
      }
    }

    /// Rejects reparse points on every intermediate component, mirroring the
    /// POSIX O_NOFOLLOW traversal guarantee.
    private static func validateComponents(rootPath: String, components: [String]) throws {
      var current = rootPath
      for component in components {
        current = current + "\\" + component
        let attributes = current.withCString(encodedAs: UTF16.self) { wide in
          GetFileAttributesW(wide)
        }
        guard attributes != INVALID_FILE_ATTRIBUTES,
          attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
        else {
          throw PathSecurityError.pathEscapeBlocked
        }
      }
    }

    static func readFile(_ handle: HANDLE, maximumBytes: Int) throws -> Data {
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumBytes + 1))
      while result.count <= maximumBytes {
        let requested = min(buffer.count, maximumBytes + 1 - result.count)
        let count = try readOnce(handle, buffer: &buffer, requested: requested)
        if count == 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
      }
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }

    private static func readOnce(
      _ handle: HANDLE,
      buffer: inout [UInt8],
      requested: Int
    ) throws -> Int {
      try buffer.withUnsafeMutableBytes { raw -> Int in
        var read: DWORD = 0
        guard ReadFile(handle, raw.baseAddress, DWORD(requested), &read, nil) else {
          throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
        }
        return Int(read)
      }
    }

    static func writeFile(_ handle: HANDLE, data: Data) throws {
      try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          var written: DWORD = 0
          guard
            WriteFile(
              handle,
              UnsafeRawPointer(raw.baseAddress!).advanced(by: offset),
              DWORD(raw.count - offset),
              &written,
              nil
            ), written > 0
          else {
            throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
          }
          offset += Int(written)
        }
      }
      _ = FlushFileBuffers(handle)
    }

    static func createDirectory(_ path: String) -> Bool {
      path.withCString(encodedAs: UTF16.self) { wide in
        CreateDirectoryW(wide, nil)
      }
    }

    /// Reads a small file fully with reparse-point rejection (digest files).
    static func readSmallFile(_ path: String) throws -> [UInt8] {
      let (handle, metadata) = try openResolving(
        rootPath: path,
        components: [],
        desiredAccess: DWORD(GENERIC_READ),
        creationDisposition: DWORD(OPEN_EXISTING),
        finalIsDirectory: false
      )
      defer { close(handle) }
      guard (64...66).contains(metadata.size) else {
        throw PathSecurityError.fileTooLarge(maximumBytes: 66)
      }
      let data = try readFile(handle, maximumBytes: 66)
      return [UInt8](data)
    }
  }
#endif
#if os(Windows)
  extension WindowsSecureFile {
    /// Reads a file through the validated traversal and returns its bytes and
    /// identity, mirroring the POSIX fd-validated read path.
    static func readValidated(
      root: RegisteredRoot,
      components: [String],
      expectedIdentity: FileSystemIdentity?,
      maximumBytes: Int
    ) throws -> (Data, Identity) {
      try validateRootIdentity(root: root)
      let (handle, metadata) = try openResolving(
        rootPath: root.canonicalPath,
        components: components,
        desiredAccess: DWORD(GENERIC_READ),
        creationDisposition: DWORD(OPEN_EXISTING),
        finalIsDirectory: false
      )
      defer { close(handle) }
      if let expectedIdentity,
        metadata.identity.device != expectedIdentity.device
          || metadata.identity.inode != expectedIdentity.inode
      {
        throw PathSecurityError.fileIdentityChanged
      }
      guard metadata.size <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }
      return (try readFile(handle, maximumBytes: maximumBytes), metadata.identity)
    }

    /// Creates a file exclusively and writes content durably (CREATE_NEW).
    static func createExclusive(
      root: RegisteredRoot,
      components: [String],
      content: Data
    ) throws {
      try validateRootIdentity(root: root)
      let (handle, _) = try openResolving(
        rootPath: root.canonicalPath,
        components: components,
        desiredAccess: DWORD(GENERIC_WRITE),
        creationDisposition: DWORD(CREATE_NEW),
        finalIsDirectory: false
      )
      defer { close(handle) }
      try writeFile(handle, data: content)
    }

    /// Stages content next to the target and atomically renames over it.
    static func replaceFile(
      root: RegisteredRoot,
      components: [String],
      content: Data,
      expectedSHA256: String?
    ) throws -> SecureFileRevision {
      try validateRootIdentity(root: root)
      let parentComponents = Array(components.dropLast())
      let name = components.last!
      let targetPath = ([root.canonicalPath] + components).joined(separator: "\\")
      let parentPath = ([root.canonicalPath] + parentComponents).joined(separator: "\\")

      let (existing, _) = try readValidated(
        root: root,
        components: components,
        expectedIdentity: nil,
        maximumBytes: 1 << 30
      )
      let oldRevision = SecureFileRevision.digest(of: existing)
      if let expectedSHA256, expectedSHA256 != oldRevision.sha256 {
        throw PathSecurityError.revisionConflict
      }

      let staging = ".codexbridge.staging.\(UUID().uuidString.lowercased())"
      let stagingPath = parentPath + "\\" + staging
      try createExclusive(
        root: root,
        components: parentComponents + [staging],
        content: content
      )
      let replaced = stagingPath.withCString(encodedAs: UTF16.self) { stagingWide in
        targetPath.withCString(encodedAs: UTF16.self) { targetWide in
          MoveFileExW(stagingWide, targetWide, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
      }
      guard replaced else {
        _ = stagingPath.withCString(encodedAs: UTF16.self) { wide in
          DeleteFileW(wide)
        }
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
      return oldRevision
    }

    static func deleteFileValidated(root: RegisteredRoot, components: [String]) throws {
      try validateRootIdentity(root: root)
      try validateComponents(rootPath: root.canonicalPath, components: components)
      let targetPath = ([root.canonicalPath] + components).joined(separator: "\\")
      let deleted = targetPath.withCString(encodedAs: UTF16.self) { wide in
        DeleteFileW(wide)
      }
      guard deleted else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func moveFileValidated(
      root: RegisteredRoot,
      sourceComponents: [String],
      destinationComponents: [String],
      expectDestinationAbsent: Bool
    ) throws {
      try validateRootIdentity(root: root)
      try validateComponents(rootPath: root.canonicalPath, components: sourceComponents)
      try validateComponents(rootPath: root.canonicalPath, components: destinationComponents)
      let destinationPath = ([root.canonicalPath] + destinationComponents).joined(separator: "\\")
      if expectDestinationAbsent {
        let attributes = destinationPath.withCString(encodedAs: UTF16.self) { wide in
          GetFileAttributesW(wide)
        }
        guard attributes == INVALID_FILE_ATTRIBUTES else {
          throw PathSecurityError.targetAlreadyExists
        }
      }
      let sourcePath = ([root.canonicalPath] + sourceComponents).joined(separator: "\\")
      let moved = sourcePath.withCString(encodedAs: UTF16.self) { sourceWide in
        destinationPath.withCString(encodedAs: UTF16.self) { destinationWide in
          MoveFileExW(sourceWide, destinationWide, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
      }
      guard moved else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func createDirectoryValidated(root: RegisteredRoot, components: [String]) throws {
      try validateRootIdentity(root: root)
      try validateComponents(rootPath: root.canonicalPath, components: Array(components.dropLast()))
      let targetPath = ([root.canonicalPath] + components).joined(separator: "\\")
      let created = targetPath.withCString(encodedAs: UTF16.self) { wide in
        CreateDirectoryW(wide, nil)
      }
      guard created else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func deleteEmptyDirectoryValidated(
      root: RegisteredRoot,
      components: [String]
    ) throws {
      try validateRootIdentity(root: root)
      try validateComponents(rootPath: root.canonicalPath, components: components)
      let targetPath = ([root.canonicalPath] + components).joined(separator: "\\")
      guard directoryIsEmpty(targetPath) else {
        throw PathSecurityError.writeFailed(Int32(ERROR_DIR_NOT_EMPTY))
      }
      let removed = targetPath.withCString(encodedAs: UTF16.self) { wide in
        RemoveDirectoryW(wide)
      }
      guard removed else {
        throw PathSecurityError.writeFailed(Int32(GetLastError()))
      }
    }

    static func directoryIsEmpty(_ path: String) -> Bool {
      let pattern = path + "\\*"
      return pattern.withCString(encodedAs: UTF16.self) { wide -> Bool in
        var findData = WIN32_FIND_DATAW()
        let handle = FindFirstFileW(wide, &findData)
        guard handle != INVALID_HANDLE_VALUE else { return false }
        defer { _ = FindClose(handle) }
        repeat {
          var fileName = findData.cFileName
          let name = withUnsafeBytes(of: &fileName) { raw -> String in
            let units = raw.bindMemory(to: UInt16.self)
            let count = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units.prefix(count), as: UTF16.self)
          }
          if name != "." && name != ".." { return false }
        } while FindNextFileW(handle, &findData)
        return true
      }
    }
  }
#endif
