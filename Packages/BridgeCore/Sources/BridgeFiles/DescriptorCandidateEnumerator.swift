import BridgeSecurity
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

struct ProjectFileCandidates: Equatable, Sendable {
  let paths: [String]
  let usedTrackedPathPriority: Bool
}

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

  mutating func candidates(scope: SecureRelativePath?) async throws -> ProjectFileCandidates {
    #if canImport(Darwin)
      let rootDescriptor = Darwin.open(
        root.canonicalPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard rootDescriptor >= 0 else { throw ProjectFileError.unsafeFilesystemState }
      defer { Darwin.close(rootDescriptor) }
      try validateRootDescriptor(rootDescriptor)

      let trackedPaths = try await GitIndexPathReader(limits: limits).read(
        rootDescriptor: rootDescriptor
      )
      let scopeDescriptor = try openScope(scope, rootDescriptor: rootDescriptor)
      defer { Darwin.close(scopeDescriptor) }
      try await scanDirectory(
        descriptor: scopeDescriptor,
        relativeDirectory: scope?.value ?? "",
        depth: 0
      )
      try root.validateCurrentIdentity()
      return prioritize(trackedPaths: trackedPaths, scope: scope)
    #elseif os(Windows)
      let rootPath = root.canonicalPath
      guard let rootHandle = Self.openDirectoryHandle(rootPath) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      defer { _ = CloseHandle(rootHandle) }
      try validateRootHandle(rootHandle)

      let trackedPaths = try await GitIndexPathReader(limits: limits).read(rootPath: rootPath)
      let scopePath = try openScope(scope, rootPath: rootPath)
      try await scanDirectory(
        path: scopePath,
        relativeDirectory: scope?.value ?? "",
        depth: 0
      )
      try root.validateCurrentIdentity()
      return prioritize(trackedPaths: trackedPaths, scope: scope)
    #endif
  }

  #if canImport(Darwin)
    private mutating func scanDirectory(
      descriptor: Int32,
      relativeDirectory: String,
      depth: Int
    ) async throws {
      guard depth <= limits.maximumDirectoryDepth else {
        throw ProjectFileError.directoryDepthExceeded
      }
      for name in try directoryEntries(descriptor) {
        try Task.checkCancellation()
        if enumeratedEntries.isMultiple(of: 64) { await Task.yield() }
        try await inspect(
          name: name,
          descriptor: descriptor,
          relativeDirectory: relativeDirectory,
          depth: depth
        )
      }
    }

    private mutating func inspect(
      name: String,
      descriptor: Int32,
      relativeDirectory: String,
      depth: Int
    ) async throws {
      enumeratedEntries += 1
      guard enumeratedEntries <= limits.maximumEnumeratedEntries else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
      guard relativePath.utf8.count <= Self.maximumPathBytes else {
        throw ProjectFileError.pathLengthExceeded
      }

      var metadata = stat()
      let status = name.withCString {
        fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      guard status == 0 else { throw ProjectFileError.unsafeFilesystemState }
      guard UInt64(metadata.st_dev) == root.identity.device else { return }
      let type = metadata.st_mode & S_IFMT
      if type == S_IFDIR {
        try await inspectDirectory(
          name: name,
          relativePath: relativePath,
          descriptor: descriptor,
          depth: depth
        )
        return
      }
      guard type == S_IFREG, metadata.st_size >= 0, metadata.st_size <= limits.maximumFileBytes
      else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath) else {
        return
      }
      guard aggregatePathBytes <= Self.maximumAggregatePathBytes - relativePath.utf8.count else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      aggregatePathBytes += relativePath.utf8.count
      candidates.append(relativePath)
      guard candidates.count <= limits.maximumCandidateFiles else {
        throw ProjectFileError.candidateLimitExceeded
      }
    }

    private mutating func inspectDirectory(
      name: String,
      relativePath: String,
      descriptor: Int32,
      depth: Int
    ) async throws {
      guard !Self.ignoredDirectories.contains(name.lowercased()) else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath) else {
        return
      }
      let child = name.withCString {
        openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else { throw ProjectFileError.unsafeFilesystemState }
      defer { Darwin.close(child) }
      try validateDirectoryDescriptor(child)
      try await scanDirectory(descriptor: child, relativeDirectory: relativePath, depth: depth + 1)
    }

    private mutating func directoryEntries(_ descriptor: Int32) throws -> [String] {
      let duplicate = dup(descriptor)
      guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { Darwin.close(duplicate) }
        throw ProjectFileError.unsafeFilesystemState
      }
      defer { closedir(directory) }

      var names: [String] = []
      errno = 0
      while let entry = readdir(directory) {
        try Task.checkCancellation()
        let name = Self.entryName(entry)
        if name != "." && name != ".." { names.append(name) }
        guard names.count <= limits.maximumEnumeratedEntries - enumeratedEntries else {
          throw ProjectFileError.enumerationLimitExceeded
        }
        errno = 0
      }
      guard errno == 0 else { throw ProjectFileError.unsafeFilesystemState }
      return names.sorted()
    }

    private func openScope(
      _ scope: SecureRelativePath?,
      rootDescriptor: Int32
    ) throws -> Int32 {
      var descriptor = dup(rootDescriptor)
      guard descriptor >= 0 else { throw ProjectFileError.unsafeFilesystemState }
      for component in scope?.components ?? [] {
        let next = component.withCString {
          openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        let openError = errno
        guard next >= 0 else {
          Darwin.close(descriptor)
          throw PathSecurityError.readFailed(openError)
        }
        Darwin.close(descriptor)
        descriptor = next
        do {
          try validateDirectoryDescriptor(descriptor)
        } catch {
          Darwin.close(descriptor)
          throw error
        }
      }
      return descriptor
    }
  #elseif os(Windows)
    private mutating func scanDirectory(
      path: String,
      relativeDirectory: String,
      depth: Int
    ) async throws {
      guard depth <= limits.maximumDirectoryDepth else {
        throw ProjectFileError.directoryDepthExceeded
      }
      for name in try directoryEntries(path: path) {
        try Task.checkCancellation()
        if enumeratedEntries.isMultiple(of: 64) { await Task.yield() }
        try await inspect(
          name: name,
          in: path,
          relativeDirectory: relativeDirectory,
          depth: depth
        )
      }
    }

    private mutating func inspect(
      name: String,
      in directoryPath: String,
      relativeDirectory: String,
      depth: Int
    ) async throws {
      enumeratedEntries += 1
      guard enumeratedEntries <= limits.maximumEnumeratedEntries else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
      guard relativePath.utf8.count <= Self.maximumPathBytes else {
        throw ProjectFileError.pathLengthExceeded
      }

      guard let information = Self.entryInformation(directoryPath + "\\" + name) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      guard information.device == root.identity.device else { return }
      if information.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return }
      if information.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
        try await inspectDirectory(
          name: name,
          relativePath: relativePath,
          parentPath: directoryPath,
          depth: depth
        )
        return
      }
      guard information.size >= 0, information.size <= limits.maximumFileBytes else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath) else {
        return
      }
      guard aggregatePathBytes <= Self.maximumAggregatePathBytes - relativePath.utf8.count else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      aggregatePathBytes += relativePath.utf8.count
      candidates.append(relativePath)
      guard candidates.count <= limits.maximumCandidateFiles else {
        throw ProjectFileError.candidateLimitExceeded
      }
    }

    private mutating func inspectDirectory(
      name: String,
      relativePath: String,
      parentPath: String,
      depth: Int
    ) async throws {
      guard !Self.ignoredDirectories.contains(name.lowercased()) else { return }
      guard let securePath = try? SecureRelativePath(relativePath), policy.allows(securePath) else {
        return
      }
      let childPath = parentPath + "\\" + name
      guard let child = Self.openDirectoryHandle(childPath) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      defer { _ = CloseHandle(child) }
      try validateDirectoryHandle(child)
      try await scanDirectory(path: childPath, relativeDirectory: relativePath, depth: depth + 1)
    }

    private mutating func directoryEntries(path: String) throws -> [String] {
      let pattern = path + "\\*"
      var findData = WIN32_FIND_DATAW()
      let findHandle: HANDLE = pattern.withCString(encodedAs: UTF16.self) {
        FindFirstFileW($0, &findData)
      }
      guard findHandle != INVALID_HANDLE_VALUE else {
        throw ProjectFileError.unsafeFilesystemState
      }
      defer { _ = FindClose(findHandle) }

      var names: [String] = []
      repeat {
        try Task.checkCancellation()
        let name = withUnsafeBytes(of: &findData.cFileName) { raw in
          String(
            decodingCString: raw.bindMemory(to: UTF16.CodeUnit.self).baseAddress!,
            as: UTF16.self
          )
        }
        if name != "." && name != ".." {
          names.append(name)
          guard names.count <= limits.maximumEnumeratedEntries - enumeratedEntries else {
            throw ProjectFileError.enumerationLimitExceeded
          }
        }
      } while FindNextFileW(findHandle, &findData)
      guard GetLastError() == DWORD(ERROR_NO_MORE_FILES) else {
        throw ProjectFileError.unsafeFilesystemState
      }
      return names.sorted()
    }

    private func openScope(
      _ scope: SecureRelativePath?,
      rootPath: String
    ) throws -> String {
      var directoryPath = rootPath
      for component in scope?.components ?? [] {
        let next = directoryPath + "\\" + component
        guard let handle = Self.openDirectoryHandle(next) else {
          throw PathSecurityError.readFailed(Int32(bitPattern: GetLastError()))
        }
        defer { _ = CloseHandle(handle) }
        try validateDirectoryHandle(handle)
        directoryPath = next
      }
      return directoryPath
    }

    private func validateRootHandle(_ handle: HANDLE) throws {
      guard let information = Self.information(handle),
        information.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        information.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        information.device == root.identity.device,
        information.inode == root.identity.inode
      else {
        throw PathSecurityError.rootIdentityChanged
      }
    }

    private func validateDirectoryHandle(_ handle: HANDLE) throws {
      guard let information = Self.information(handle),
        information.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        information.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        information.device == root.identity.device
      else {
        throw ProjectFileError.unsafeFilesystemState
      }
    }

    private static func openDirectoryHandle(_ path: String) -> HANDLE? {
      let handle: HANDLE = path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      return handle == INVALID_HANDLE_VALUE ? nil : handle
    }

    fileprivate static func entryInformation(_ path: String) -> (
      device: UInt64, inode: UInt64, size: Int64, attributes: DWORD
    )? {
      let handle: HANDLE = path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard handle != INVALID_HANDLE_VALUE else { return nil }
      defer { _ = CloseHandle(handle) }
      return information(handle)
    }

    private static func information(_ handle: HANDLE) -> (
      device: UInt64, inode: UInt64, size: Int64, attributes: DWORD
    )? {
      var data = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &data) else { return nil }
      let size = (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow)
      return (
        device: UInt64(data.dwVolumeSerialNumber),
        inode: (UInt64(data.nFileIndexHigh) << 32) | UInt64(data.nFileIndexLow),
        size: Int64(bitPattern: size),
        attributes: data.dwFileAttributes
      )
    }
  #endif

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

  #if canImport(Darwin)
    private func validateRootDescriptor(_ descriptor: Int32) throws {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw ProjectFileError.unsafeFilesystemState
      }
      let identity = FileSystemIdentity(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino)
      )
      guard identity == root.identity else { throw PathSecurityError.rootIdentityChanged }
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32) throws {
      var metadata = stat()
      guard
        fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        UInt64(metadata.st_dev) == root.identity.device
      else {
        throw ProjectFileError.unsafeFilesystemState
      }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
      withUnsafePointer(to: &entry.pointee.d_name) { name in
        name.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
    }
  #endif
}

private struct GitIndexPathReader {
  private static let maximumIndexBytes = 16 * 1_024 * 1_024
  private static let maximumPathBytes = 4_096
  let limits: ProjectFileLimits

  #if os(Windows)
    func read(rootPath: String) async throws -> [String]? {
      guard let rootInformation = DescriptorCandidateEnumerator.entryInformation(rootPath)
      else { return nil }
      let gitPath = rootPath + "\\.git"
      guard
        let gitInformation = DescriptorCandidateEnumerator.entryInformation(gitPath),
        gitInformation.device == rootInformation.device,
        gitInformation.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        gitInformation.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else { return nil }
      let indexPath = gitPath + "\\index"
      guard
        let indexInformation = DescriptorCandidateEnumerator.entryInformation(indexPath),
        indexInformation.device == rootInformation.device,
        indexInformation.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        indexInformation.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        indexInformation.size >= 0,
        indexInformation.size <= Self.maximumIndexBytes
      else { return nil }
      guard let data = try await boundedData(path: indexPath) else { return nil }
      return try await parse(data)
    }

    private func boundedData(path: String) async throws -> Data? {
      let handle: HANDLE = path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard handle != INVALID_HANDLE_VALUE else { return nil }
      defer { _ = CloseHandle(handle) }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while data.count <= Self.maximumIndexBytes {
        try Task.checkCancellation()
        await Task.yield()
        var received: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &received, nil)
        }
        guard succeeded else { return nil }
        if received == 0 { return data }
        data.append(contentsOf: buffer.prefix(Int(received)))
      }
      return nil
    }
  #else
    func read(rootDescriptor: Int32) async throws -> [String]? {
      guard let rootDevice = device(of: rootDescriptor) else { return nil }
      let gitDescriptor = ".git".withCString {
        openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard gitDescriptor >= 0, device(of: gitDescriptor) == rootDevice else {
        if gitDescriptor >= 0 { Darwin.close(gitDescriptor) }
        return nil
      }
      defer { Darwin.close(gitDescriptor) }
      let indexDescriptor = "index".withCString {
        openat(gitDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard indexDescriptor >= 0, device(of: indexDescriptor) == rootDevice else {
        if indexDescriptor >= 0 { Darwin.close(indexDescriptor) }
        return nil
      }
      defer { Darwin.close(indexDescriptor) }
      guard let data = try await boundedData(indexDescriptor) else { return nil }
      return try await parse(data)
    }

    private func device(of descriptor: Int32) -> UInt64? {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else { return nil }
      return UInt64(metadata.st_dev)
    }

    private func boundedData(_ descriptor: Int32) async throws -> Data? {
      var metadata = stat()
      guard
        fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_size >= 0,
        metadata.st_size <= Self.maximumIndexBytes
      else { return nil }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while data.count <= Self.maximumIndexBytes {
        try Task.checkCancellation()
        await Task.yield()
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return data }
        if count > 0 {
          data.append(contentsOf: buffer.prefix(count))
          continue
        }
        if errno != EINTR { return nil }
      }
      return nil
    }
  #endif

  private func parse(_ data: Data) async throws -> [String]? {
    guard
      data.count >= 12,
      data.prefix(4) == Data("DIRC".utf8),
      let version = data.uint32(at: 4),
      version == 2 || version == 3,
      let entryCountValue = data.uint32(at: 8)
    else { return nil }
    let entryCount = Int(entryCountValue)
    guard entryCount <= limits.maximumEnumeratedEntries else { return nil }

    var offset = 12
    var paths: [String] = []
    for index in 0..<entryCount {
      try Task.checkCancellation()
      if index.isMultiple(of: 256) { await Task.yield() }
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
    guard offset <= data.count - 62, let flags = data.uint16(at: offset + 60) else { return nil }
    var pathOffset = offset + 62
    if version == 3 && flags & 0x4000 != 0 { pathOffset += 2 }
    guard pathOffset < data.count else { return nil }
    let declaredLength = Int(flags & 0x0FFF)
    let terminator = data[pathOffset...].firstIndex(of: 0)
    guard let terminator, terminator - pathOffset <= Self.maximumPathBytes else { return nil }
    let pathData = data[pathOffset..<terminator]
    if declaredLength < 0x0FFF && pathData.count != declaredLength { return nil }
    let nextOffset = paddedOffset(after: terminator + 1, entryStart: entryStart)
    guard nextOffset <= data.count else { return nil }
    guard let path = String(data: pathData, encoding: .utf8),
      let secure = try? SecureRelativePath(path)
    else {
      return (nil, nextOffset)
    }
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
