#if canImport(WinSDK)
  import BridgeSecurity
  import Foundation
  import WinSDK

  struct DescriptorCandidateEnumerator {
    private static let ignoredDirectories: Set<String> = [
      ".build", ".cache", ".git", ".gradle", ".next", ".swiftpm", ".turbo",
      "build", "coverage", "deriveddata", "dist", "node_modules",
    ]
    private static let maximumPathBytes = 4_096
    private static let maximumAggregatePathBytes = 8 * 1_024 * 1_024

    let root: RegisteredRoot
    let policy: ProjectFilePolicy
    let limits: ProjectFileLimits
    private var enumeratedEntries = 0
    private var aggregatePathBytes = 0
    private var candidates: [String] = []

    init(root: RegisteredRoot, policy: ProjectFilePolicy, limits: ProjectFileLimits) {
      self.root = root
      self.policy = policy
      self.limits = limits
    }

    mutating func candidates(scope: SecureRelativePath?) throws -> ProjectFileCandidates {
      if let scope {
        try WindowsEnumeratorSupport.validate(scope: scope)
      }
      let rootHandle = try WindowsEnumeratorSupport.openDirectory(path: root.canonicalPath)
      defer { CloseHandle(rootHandle) }
      try WindowsEnumeratorSupport.validateDirectory(
        rootHandle,
        expectedPath: root.canonicalPath,
        root: root,
        requireRootIdentity: true
      )

      let trackedPaths = WindowsGitIndexPathReader(limits: limits).read(
        rootPath: root.canonicalPath,
        root: root
      )
      let scopeHandle = try openScope(scope)
      defer { CloseHandle(scopeHandle.handle) }
      try scanDirectory(
        path: scopeHandle.path,
        relativeDirectory: scope?.value ?? "",
        depth: 0
      )
      try root.validateCurrentIdentity()
      return prioritize(trackedPaths: trackedPaths, scope: scope)
    }

    private mutating func scanDirectory(
      path: String,
      relativeDirectory: String,
      depth: Int
    ) throws {
      guard depth <= limits.maximumDirectoryDepth else {
        throw ProjectFileError.directoryDepthExceeded
      }
      for name in try directoryEntries(path: path) {
        try inspect(
          name: name,
          parentPath: path,
          relativeDirectory: relativeDirectory,
          depth: depth
        )
      }
    }

    private mutating func inspect(
      name: String,
      parentPath: String,
      relativeDirectory: String,
      depth: Int
    ) throws {
      enumeratedEntries += 1
      guard enumeratedEntries <= limits.maximumEnumeratedEntries else {
        throw ProjectFileError.enumerationLimitExceeded
      }

      let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
      guard relativePath.utf8.count <= Self.maximumPathBytes else {
        throw ProjectFileError.pathLengthExceeded
      }
      guard WindowsEnumeratorSupport.isValidComponent(name) else { return }
      let childPath = WindowsEnumeratorSupport.join(parentPath, name)
      let childHandle = try WindowsEnumeratorSupport.openEntry(path: childPath)
      defer { CloseHandle(childHandle) }

      let attributes = try WindowsEnumeratorSupport.attributes(of: childHandle)
      // A reparse point is the Windows equivalent of a symlink/junction here.
      // It is skipped like Darwin's AT_SYMLINK_NOFOLLOW path, never traversed.
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { return }
      let identity = try WindowsEnumeratorSupport.identity(of: childHandle)
      guard identity.volumeID == root.identity.volumeID else { return }
      guard
        WindowsEnumeratorSupport.equivalent(
          try WindowsEnumeratorSupport.finalPath(of: childHandle),
          childPath
        )
      else {
        throw ProjectFileError.unsafeFilesystemState
      }

      let isDirectory = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      if isDirectory {
        try inspectDirectory(
          name: name,
          relativePath: relativePath,
          path: childPath,
          depth: depth
        )
        return
      }
      try appendRegularFile(
        relativePath: relativePath,
        handle: childHandle,
        attributes: attributes
      )
    }

    private mutating func inspectDirectory(
      name: String,
      relativePath: String,
      path: String,
      depth: Int
    ) throws {
      guard !Self.ignoredDirectories.contains(name.lowercased()) else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath)
      else { return }
      try scanDirectory(
        path: path,
        relativeDirectory: relativePath,
        depth: depth + 1
      )
    }

    private mutating func appendRegularFile(
      relativePath: String,
      handle: HANDLE,
      attributes: DWORD
    ) throws {
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else { return }
      let fileType = GetFileType(handle)
      guard fileType != DWORD(0) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      guard fileType == DWORD(FILE_TYPE_DISK) else { return }
      var size = LARGE_INTEGER()
      guard GetFileSizeEx(handle, &size), size.QuadPart >= 0,
        UInt64(size.QuadPart) <= UInt64(Int.max)
      else {
        throw ProjectFileError.unsafeFilesystemState
      }
      guard size.QuadPart <= Int64(limits.maximumFileBytes) else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath)
      else { return }
      guard aggregatePathBytes <= Self.maximumAggregatePathBytes - relativePath.utf8.count
      else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      aggregatePathBytes += relativePath.utf8.count
      candidates.append(relativePath)
      guard candidates.count <= limits.maximumCandidateFiles else {
        throw ProjectFileError.candidateLimitExceeded
      }
    }

    private func directoryEntries(path: String) throws -> [String] {
      var data = WIN32_FIND_DATAW()
      let pattern = WindowsEnumeratorSupport.join(path, "*")
      let search = WindowsEnumeratorSupport.findFirst(pattern: pattern, data: &data)
      guard let search, search != INVALID_HANDLE_VALUE else {
        let error = GetLastError()
        if error == ERROR_FILE_NOT_FOUND { return [] }
        throw ProjectFileError.unsafeFilesystemState
      }
      defer { FindClose(search) }

      var names: [String] = []
      while true {
        let name = Self.findName(data)
        if name != "." && name != ".." { names.append(name) }
        guard names.count <= limits.maximumEnumeratedEntries - enumeratedEntries else {
          throw ProjectFileError.enumerationLimitExceeded
        }
        guard FindNextFileW(search, &data) else {
          guard GetLastError() == ERROR_NO_MORE_FILES else {
            throw ProjectFileError.unsafeFilesystemState
          }
          break
        }
      }
      return names.sorted()
    }

    private func openScope(_ scope: SecureRelativePath?) throws -> (handle: HANDLE, path: String) {
      var path = root.canonicalPath
      var handle = try WindowsEnumeratorSupport.openDirectory(path: path)
      do {
        try WindowsEnumeratorSupport.validateDirectory(
          handle,
          expectedPath: path,
          root: root,
          requireRootIdentity: true
        )
        for component in scope?.components ?? [] {
          let nextPath = WindowsEnumeratorSupport.join(path, component)
          let next = try WindowsEnumeratorSupport.openDirectory(path: nextPath)
          do {
            try WindowsEnumeratorSupport.validateDirectory(
              next,
              expectedPath: nextPath,
              root: root,
              requireRootIdentity: false
            )
          } catch {
            CloseHandle(next)
            throw error
          }
          CloseHandle(handle)
          handle = next
          path = nextPath
        }
        return (handle, path)
      } catch {
        CloseHandle(handle)
        throw error
      }
    }

    private func prioritize(
      trackedPaths: [String]?,
      scope: SecureRelativePath?
    ) -> ProjectFileCandidates {
      let enumerated = candidates.sorted()
      guard let trackedPaths else {
        return ProjectFileCandidates(paths: enumerated, usedTrackedPathPriority: false)
      }
      let available = Set(enumerated)
      let prioritized = trackedPaths.filter { available.contains($0) && isInside($0, scope: scope) }
      let prioritizedSet = Set(prioritized)
      return ProjectFileCandidates(
        paths: prioritized + enumerated.filter { !prioritizedSet.contains($0) },
        usedTrackedPathPriority: true
      )
    }

    private func isInside(_ path: String, scope: SecureRelativePath?) -> Bool {
      guard let scope else { return true }
      return path.hasPrefix(scope.value + "/")
    }

    private static func findName(_ data: WIN32_FIND_DATAW) -> String {
      withUnsafeBytes(of: data.cFileName) { bytes in
        let units = bytes.bindMemory(to: UInt16.self)
        let end = units.firstIndex(of: 0) ?? units.count
        return String(decoding: units[..<end], as: UTF16.self)
      }
    }
  }

  private enum WindowsEnumeratorSupport {
    private static let genericRead = DWORD(0x8000_0000)
    private static let defaultShare = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
    private static let openFlags = DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)

    static func join(_ parent: String, _ name: String) -> String {
      let normalized = normalize(parent)
      return normalized.hasSuffix("\\") ? normalized + name : normalized + "\\" + name
    }

    static func validate(scope: SecureRelativePath) throws {
      for component in scope.components {
        guard isValidComponent(component) else {
          throw PathSecurityError.invalidRelativePath("invalid Windows path component")
        }
      }
    }

    static func isValidComponent(_ component: String) -> Bool {
      guard !component.isEmpty, component.utf16.count <= 255,
        component.last != ".", component.last != " "
      else { return false }
      guard
        !component.unicodeScalars.contains(where: { scalar in
          scalar.value < 0x20 || #"<>:"/\|?*"#.unicodeScalars.contains(scalar)
        })
      else { return false }
      let stem = component.split(separator: ".", maxSplits: 1).first.map(String.init) ?? component
      let upper = stem.uppercased()
      if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(upper) {
        return false
      }
      for prefix in ["COM", "LPT"] where upper.count == 4 && upper.hasPrefix(prefix) {
        if let suffix = upper.last, suffix >= "1", suffix <= "9" { return false }
      }
      return true
    }

    static func openDirectory(path: String) throws -> HANDLE {
      try open(path: path, access: DWORD(0), flags: openFlags)
    }

    static func openEntry(path: String) throws -> HANDLE {
      try open(path: path, access: DWORD(0), flags: openFlags)
    }

    static func openFileForRead(path: String) throws -> HANDLE? {
      let raw = withWide(path) { wide in
        CreateFileW(
          wide,
          genericRead,
          defaultShare,
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle = raw, handle != INVALID_HANDLE_VALUE else {
        let error = GetLastError()
        if error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND { return nil }
        throw ProjectFileError.unsafeFilesystemState
      }
      return handle
    }

    static func attributes(of handle: HANDLE) throws -> DWORD {
      var info = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &info,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw ProjectFileError.unsafeFilesystemState
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
        throw ProjectFileError.unsafeFilesystemState
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

    static func validateDirectory(
      _ handle: HANDLE,
      expectedPath: String,
      root: RegisteredRoot,
      requireRootIdentity: Bool
    ) throws {
      let attributes = try attributes(of: handle)
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      else {
        throw ProjectFileError.unsafeFilesystemState
      }
      let identity = try identity(of: handle)
      if requireRootIdentity {
        guard identity == root.identity else {
          throw PathSecurityError.rootIdentityChanged
        }
      } else {
        guard identity.volumeID == root.identity.volumeID else {
          throw ProjectFileError.unsafeFilesystemState
        }
      }
      guard equivalent(try finalPath(of: handle), expectedPath) else {
        throw ProjectFileError.unsafeFilesystemState
      }
    }

    static func finalPath(of handle: HANDLE) throws -> String {
      let flags = DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
      let length = GetFinalPathNameByHandleW(handle, nil, 0, flags)
      guard length > 0 else { throw ProjectFileError.unsafeFilesystemState }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let capacity = DWORD(buffer.count)
      let written = buffer.withUnsafeMutableBufferPointer { pointer in
        GetFinalPathNameByHandleW(handle, pointer.baseAddress, capacity, flags)
      }
      guard written > 0, written < DWORD(buffer.count) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
    }

    static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
      normalize(lhs).caseInsensitiveCompare(normalize(rhs)) == .orderedSame
    }

    static func findFirst(
      pattern: String,
      data: UnsafeMutablePointer<WIN32_FIND_DATAW>
    ) -> HANDLE? {
      withWide(pattern) { FindFirstFileW($0, data) }
    }

    private static func open(path: String, access: DWORD, flags: DWORD) throws -> HANDLE {
      let raw = withWide(path) { wide in
        CreateFileW(
          wide,
          access,
          defaultShare,
          nil,
          DWORD(OPEN_EXISTING),
          flags,
          nil
        )
      }
      guard let handle = raw, handle != INVALID_HANDLE_VALUE else {
        throw ProjectFileError.unsafeFilesystemState
      }
      return handle
    }

    private static func normalize(_ path: String) -> String {
      var value = path.replacingOccurrences(of: "/", with: "\\")
      if value.hasPrefix("\\\\?\\UNC\\") {
        value = "\\\\" + String(value.dropFirst(8))
      } else if value.hasPrefix("\\\\?\\") {
        value = String(value.dropFirst(4))
      }
      while value.count > 3, value.hasSuffix("\\") { value.removeLast() }
      return value
    }

    private static func apiPath(_ path: String) -> String {
      let value = normalize(path)
      if value.hasPrefix("\\\\") || value.hasPrefix("\\\\?\\") {
        return value
      }
      return "\\\\?\\" + value
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

  private struct WindowsGitIndexPathReader {
    private static let maximumIndexBytes = 16 * 1_024 * 1_024
    private static let maximumPathBytes = 4_096
    let limits: ProjectFileLimits

    func read(rootPath: String, root: RegisteredRoot) -> [String]? {
      guard
        let gitHandle = try? WindowsEnumeratorSupport.openDirectory(
          path: WindowsEnumeratorSupport.join(rootPath, ".git")
        )
      else { return nil }
      defer { CloseHandle(gitHandle) }
      guard
        (try? WindowsEnumeratorSupport.attributes(of: gitHandle))
          .map({
            $0 & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
              && $0 & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
          }) == true,
        (try? WindowsEnumeratorSupport.identity(of: gitHandle).volumeID)
          == root.identity.volumeID,
        (try? WindowsEnumeratorSupport.finalPath(of: gitHandle))
          .map({
            WindowsEnumeratorSupport.equivalent($0, WindowsEnumeratorSupport.join(rootPath, ".git"))
          }) == true
      else { return nil }

      guard
        let indexHandle = try? WindowsEnumeratorSupport.openFileForRead(
          path: WindowsEnumeratorSupport.join(rootPath, ".git/index")
        )
      else { return nil }
      defer { CloseHandle(indexHandle) }
      guard
        (try? WindowsEnumeratorSupport.attributes(of: indexHandle))
          .map({
            $0 & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
              && $0 & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
              && GetFileType(indexHandle) == DWORD(FILE_TYPE_DISK)
          }) == true,
        (try? WindowsEnumeratorSupport.identity(of: indexHandle).volumeID)
          == root.identity.volumeID,
        (try? WindowsEnumeratorSupport.finalPath(of: indexHandle))
          .map({
            WindowsEnumeratorSupport.equivalent(
              $0, WindowsEnumeratorSupport.join(rootPath, ".git/index"))
          }) == true,
        let data = boundedData(indexHandle)
      else { return nil }
      return parse(data)
    }

    private func boundedData(_ handle: HANDLE) -> Data? {
      var size = LARGE_INTEGER()
      guard GetFileSizeEx(handle, &size), size.QuadPart >= 0,
        size.QuadPart <= Int64(Self.maximumIndexBytes)
      else { return nil }

      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while data.count <= Self.maximumIndexBytes {
        let requested = min(buffer.count, Self.maximumIndexBytes + 1 - data.count)
        var readBytes = DWORD(0)
        let didRead = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(requested), &readBytes, nil)
        }
        guard didRead else { return nil }
        if readBytes == 0 { return data }
        data.append(contentsOf: buffer.prefix(Int(readBytes)))
      }
      return nil
    }

    private func parse(_ data: Data) -> [String]? {
      guard data.count >= 12, data.prefix(4) == Data("DIRC".utf8),
        let version = data.uint32(at: 4), version == 2 || version == 3,
        let countValue = data.uint32(at: 8)
      else { return nil }
      let count = Int(countValue)
      guard count <= limits.maximumEnumeratedEntries else { return nil }

      var offset = 12
      var paths: [String] = []
      for _ in 0..<count {
        guard let entry = parseEntry(data, offset: offset, version: version) else { return nil }
        offset = entry.nextOffset
        if let path = entry.path { paths.append(path) }
        if paths.count > limits.maximumCandidateFiles { return nil }
      }
      return Array(Set(paths)).sorted()
    }

    private func parseEntry(
      _ data: Data,
      offset: Int,
      version: UInt32
    ) -> (path: String?, nextOffset: Int)? {
      let entryStart = offset
      guard offset <= data.count - 62, let flags = data.uint16(at: offset + 60) else {
        return nil
      }
      var pathOffset = offset + 62
      if version == 3 && flags & 0x4000 != 0 { pathOffset += 2 }
      guard pathOffset < data.count else { return nil }
      let declaredLength = Int(flags & 0x0FFF)
      guard let terminator = data[pathOffset...].firstIndex(of: 0),
        terminator - pathOffset <= Self.maximumPathBytes
      else { return nil }
      let pathData = data[pathOffset..<terminator]
      if declaredLength < 0x0FFF && pathData.count != declaredLength { return nil }
      let nextOffset = paddedOffset(after: terminator + 1, entryStart: entryStart)
      guard nextOffset <= data.count else { return nil }
      guard let path = String(data: pathData, encoding: .utf8),
        let secure = try? SecureRelativePath(path)
      else { return (nil, nextOffset) }
      return (secure.value, nextOffset)
    }

    private func paddedOffset(after value: Int, entryStart: Int) -> Int {
      let consumed = value - entryStart
      return value + (8 - consumed % 8) % 8
    }
  }

  extension Data {
    fileprivate func uint16(at offset: Int) -> UInt16? {
      guard offset >= 0, offset <= count - 2 else { return nil }
      return self[offset...].prefix(2).reduce(0) { ($0 << 8) | UInt16($1) }
    }

    fileprivate func uint32(at offset: Int) -> UInt32? {
      guard offset >= 0, offset <= count - 4 else { return nil }
      return self[offset...].prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
  }
#endif
