import BridgeSecurity
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

struct ProjectFileCandidates: Equatable, Sendable {
  let paths: [String]
  let usedTrackedPathPriority: Bool
}

#if canImport(Darwin)
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

    mutating func candidates(scope: SecureRelativePath?) throws -> ProjectFileCandidates {
      let rootDescriptor = Darwin.open(
        root.canonicalPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard rootDescriptor >= 0 else { throw ProjectFileError.unsafeFilesystemState }
      defer { Darwin.close(rootDescriptor) }
      try validateRootDescriptor(rootDescriptor)

      let trackedPaths = GitIndexPathReader(limits: limits).read(rootDescriptor: rootDescriptor)
      let scopeDescriptor = try openScope(scope, rootDescriptor: rootDescriptor)
      defer { Darwin.close(scopeDescriptor) }
      try scanDirectory(
        descriptor: scopeDescriptor,
        relativeDirectory: scope?.value ?? "",
        depth: 0
      )
      try root.validateCurrentIdentity()
      return prioritize(trackedPaths: trackedPaths, scope: scope)
    }

    private mutating func scanDirectory(
      descriptor: Int32,
      relativeDirectory: String,
      depth: Int
    ) throws {
      guard depth <= limits.maximumDirectoryDepth else {
        throw ProjectFileError.directoryDepthExceeded
      }
      for name in try directoryEntries(descriptor) {
        try inspect(
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
    ) throws {
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
      guard String(UInt64(metadata.st_dev)) == root.identity.volumeID else { return }
      let type = metadata.st_mode & S_IFMT
      if type == S_IFDIR {
        try inspectDirectory(
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
    ) throws {
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
      try scanDirectory(descriptor: child, relativeDirectory: relativePath, depth: depth + 1)
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

    private func validateRootDescriptor(_ descriptor: Int32) throws {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw ProjectFileError.unsafeFilesystemState
      }
      let identity = FileSystemIdentity(
        posixDevice: UInt64(metadata.st_dev),
        posixInode: UInt64(metadata.st_ino)
      )
      guard identity == root.identity else { throw PathSecurityError.rootIdentityChanged }
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32) throws {
      var metadata = stat()
      guard
        fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        String(UInt64(metadata.st_dev)) == root.identity.volumeID
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
  }

  private struct GitIndexPathReader {
    private static let maximumIndexBytes = 16 * 1_024 * 1_024
    private static let maximumPathBytes = 4_096
    let limits: ProjectFileLimits

    func read(rootDescriptor: Int32) -> [String]? {
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
      guard let data = boundedData(indexDescriptor) else { return nil }
      return parse(data)
    }

    private func device(of descriptor: Int32) -> UInt64? {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else { return nil }
      return UInt64(metadata.st_dev)
    }

    private func boundedData(_ descriptor: Int32) -> Data? {
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

    private func parse(_ data: Data) -> [String]? {
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
      for _ in 0..<entryCount {
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
#endif
