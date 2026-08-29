import Crypto
import Darwin
import Foundation

public enum SecureDirectoryAction: Equatable, Sendable {
  case deleteFile(expectedSHA256: String?)
  case moveFile(sourceExpectedSHA256: String?, destinationExpectedAbsent: Bool)
  case createDirectory
  case deleteEmptyDirectory
}

public struct SecureDirectoryMutationResult: Equatable, Sendable {
  public let action: SecureDirectoryAction
  public let revision: SecureFileRevision?
}

public struct SecureProjectDirectoryMutation: Sendable {
  public let maximumBytes: Int

  public init(maximumBytes: Int = 200 * 1_024) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func apply(
    action: SecureDirectoryAction,
    relativePath: SecureRelativePath,
    destinationRelativePath: SecureRelativePath?,
    through resolver: ProjectPathResolver
  ) throws -> SecureDirectoryMutationResult {
    try resolver.root.validateCurrentIdentity()
    guard resolver.sensitivePolicy.allows(relativePath) else {
      throw PathSecurityError.sensitiveFileBlocked
    }
    if let destinationRelativePath,
      resolver.sensitivePolicy.allows(destinationRelativePath) == false
    {
      throw PathSecurityError.sensitiveFileBlocked
    }

    let rootFD = open(
      resolver.root.canonicalPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootFD >= 0 else { throw PathSecurityError.writeFailed(errno) }
    defer { close(rootFD) }
    try validateRootDescriptor(rootFD, root: resolver.root)

    switch action {
    case .deleteFile(let expectedSHA256):
      return try deleteFile(
        relativePath: relativePath,
        expectedSHA256: expectedSHA256,
        rootFD: rootFD,
        root: resolver.root
      )
    case .moveFile(let sourceExpectedSHA256, let destinationExpectedAbsent):
      guard let destinationRelativePath else {
        throw PathSecurityError.invalidRelativePath("missing destination")
      }
      return try moveFile(
        sourcePath: relativePath,
        destinationPath: destinationRelativePath,
        sourceExpectedSHA256: sourceExpectedSHA256,
        destinationExpectedAbsent: destinationExpectedAbsent,
        rootFD: rootFD,
        root: resolver.root
      )
    case .createDirectory:
      return try createDirectory(relativePath: relativePath, rootFD: rootFD, root: resolver.root)
    case .deleteEmptyDirectory:
      return try deleteEmptyDirectory(
        relativePath: relativePath, rootFD: rootFD, root: resolver.root)
    }
  }

  private func deleteFile(
    relativePath: SecureRelativePath,
    expectedSHA256: String?,
    rootFD: Int32,
    root: RegisteredRoot
  ) throws -> SecureDirectoryMutationResult {
    let (parentFD, name) = try openParent(relativePath: relativePath, rootFD: rootFD, root: root)
    defer { close(parentFD) }
    let target = name.withCString {
      openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard target >= 0 else { throw PathSecurityError.writeFailed(errno) }
    defer { close(target) }
    let metadata = try validateRegularDescriptor(target, root: root)
    guard metadata.st_nlink <= 1 else { throw PathSecurityError.unsupportedHardLink }
    guard metadata.st_size <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    let data = try readFull(descriptor: target, maximumBytes: maximumBytes)
    let revision = SecureFileRevision.digest(of: data)
    if let expectedSHA256, expectedSHA256 != revision.sha256 {
      throw PathSecurityError.revisionConflict
    }
    let before = try statOf(target)
    guard sameFile(before, metadata) else { throw PathSecurityError.pathChanged }
    guard name.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else {
      throw PathSecurityError.writeFailed(errno)
    }
    guard fsync(parentFD) == 0 else {
      throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
    }
    return SecureDirectoryMutationResult(
      action: .deleteFile(expectedSHA256: expectedSHA256), revision: revision)
  }

  private func moveFile(
    sourcePath: SecureRelativePath,
    destinationPath: SecureRelativePath,
    sourceExpectedSHA256: String?,
    destinationExpectedAbsent: Bool,
    rootFD: Int32,
    root: RegisteredRoot
  ) throws -> SecureDirectoryMutationResult {
    let (sourceParentFD, sourceName) = try openParent(
      relativePath: sourcePath, rootFD: rootFD, root: root)
    defer { close(sourceParentFD) }
    let (destinationParentFD, destinationName) = try openParent(
      relativePath: destinationPath, rootFD: rootFD, root: root)
    defer { close(destinationParentFD) }

    let target = sourceName.withCString {
      openat(sourceParentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard target >= 0 else { throw PathSecurityError.writeFailed(errno) }
    defer { close(target) }
    let metadata = try validateRegularDescriptor(target, root: root)
    guard metadata.st_nlink <= 1 else { throw PathSecurityError.unsupportedHardLink }
    guard metadata.st_size <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    let data = try readFull(descriptor: target, maximumBytes: maximumBytes)
    let revision = SecureFileRevision.digest(of: data)
    if let sourceExpectedSHA256, sourceExpectedSHA256 != revision.sha256 {
      throw PathSecurityError.revisionConflict
    }

    if destinationExpectedAbsent {
      let probe = destinationName.withCString {
        openat(destinationParentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      }
      if probe >= 0 {
        close(probe)
        throw PathSecurityError.targetAlreadyExists
      }
      guard errno == ENOENT || errno == ENOTDIR else {
        throw PathSecurityError.writeFailed(errno)
      }
    }

    let before = try statOf(target)
    guard sameFile(before, metadata) else { throw PathSecurityError.pathChanged }

    guard renameat(sourceParentFD, sourceName, destinationParentFD, destinationName) == 0 else {
      throw PathSecurityError.writeFailed(errno)
    }
    guard fsync(destinationParentFD) == 0, fsync(sourceParentFD) == 0 else {
      throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
    }
    return SecureDirectoryMutationResult(
      action: .moveFile(
        sourceExpectedSHA256: sourceExpectedSHA256,
        destinationExpectedAbsent: destinationExpectedAbsent
      ), revision: revision)
  }

  private func createDirectory(
    relativePath: SecureRelativePath,
    rootFD: Int32,
    root: RegisteredRoot
  ) throws -> SecureDirectoryMutationResult {
    let (parentFD, name) = try openParent(relativePath: relativePath, rootFD: rootFD, root: root)
    defer { close(parentFD) }
    guard name.withCString({ mkdirat(parentFD, $0, 0o755) }) == 0 else {
      throw PathSecurityError.writeFailed(errno)
    }
    let created = name.withCString {
      openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard created >= 0 else { throw PathSecurityError.writeFailed(errno) }
    defer { close(created) }
    guard validateDirectoryDescriptor(created, root: root) else {
      throw PathSecurityError.pathEscapeBlocked
    }
    guard fsync(parentFD) == 0 else {
      throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
    }
    return SecureDirectoryMutationResult(action: .createDirectory, revision: nil)
  }

  private func deleteEmptyDirectory(
    relativePath: SecureRelativePath,
    rootFD: Int32,
    root: RegisteredRoot
  ) throws -> SecureDirectoryMutationResult {
    let (parentFD, name) = try openParent(relativePath: relativePath, rootFD: rootFD, root: root)
    defer { close(parentFD) }
    var directory = name.withCString {
      openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directory >= 0 else { throw PathSecurityError.writeFailed(errno) }
    guard validateDirectoryDescriptor(directory, root: root) else {
      close(directory)
      throw PathSecurityError.pathEscapeBlocked
    }
    guard directoryIsEmpty(directory) else {
      close(directory)
      throw PathSecurityError.unsupportedFileType
    }
    close(directory)
    directory = -1
    guard name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else {
      throw PathSecurityError.writeFailed(errno)
    }
    guard fsync(parentFD) == 0 else {
      throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
    }
    return SecureDirectoryMutationResult(action: .deleteEmptyDirectory, revision: nil)
  }

  private func openParent(
    relativePath: SecureRelativePath,
    rootFD: Int32,
    root: RegisteredRoot
  ) throws -> (Int32, String) {
    let components = relativePath.components
    guard !components.isEmpty else { throw PathSecurityError.invalidRelativePath("empty path") }
    var current = rootFD
    var currentIsRoot = true
    for component in components.dropLast() {
      let next = component.withCString {
        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      let openError = errno
      if !currentIsRoot { close(current) }
      current = -1
      guard next >= 0 else {
        if openError == ENOENT || openError == ENOTDIR {
          throw PathSecurityError.pathDoesNotExist
        }
        throw PathSecurityError.writeFailed(openError)
      }
      guard validateDirectoryDescriptor(next, root: root) else {
        close(next)
        throw PathSecurityError.pathEscapeBlocked
      }
      current = next
      currentIsRoot = false
    }
    if currentIsRoot {
      let duplicate = dup(rootFD)
      guard duplicate >= 0 else { throw PathSecurityError.writeFailed(errno) }
      return (duplicate, components[components.count - 1])
    }
    return (current, components[components.count - 1])
  }

  private func directoryIsEmpty(_ descriptor: Int32) -> Bool {
    guard let stream = fdopendir(descriptor) else { return false }
    defer { closedir(stream) }
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      if name != "." && name != ".." { return false }
    }
    return true
  }

  private func statOf(_ descriptor: Int32) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw PathSecurityError.writeFailed(errno) }
    return metadata
  }

  private func sameFile(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev
      && a.st_ino == b.st_ino
      && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
  }

  private func validateRootDescriptor(_ descriptor: Int32, root: RegisteredRoot) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw PathSecurityError.writeFailed(errno) }
    guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
      throw PathSecurityError.rootUnavailable
    }
    let identity = FileSystemIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
    guard identity == root.identity else {
      throw PathSecurityError.rootIdentityChanged
    }
  }

  private func validateDirectoryDescriptor(_ descriptor: Int32, root: RegisteredRoot) -> Bool {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
      return false
    }
    let identity = FileSystemIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
    return identity.device == root.identity.device
  }

  private func validateRegularDescriptor(_ descriptor: Int32, root: RegisteredRoot) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw PathSecurityError.writeFailed(errno) }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw PathSecurityError.unsupportedFileType
    }
    let identity = FileSystemIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
    guard identity.device == root.identity.device else {
      throw PathSecurityError.pathEscapeBlocked
    }
    return metadata
  }

  private func readFull(descriptor: Int32, maximumBytes: Int) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, maximumBytes + 1))
    while result.count <= maximumBytes {
      let requested = min(buffer.count, maximumBytes + 1 - result.count)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requested)
      }
      if count == 0 { return result }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw PathSecurityError.readFailed(errno)
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
  }
}
