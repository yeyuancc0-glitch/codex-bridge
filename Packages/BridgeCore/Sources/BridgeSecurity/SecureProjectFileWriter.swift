import CryptoKit
import Darwin
import Foundation

public struct SecureFileRevision: Equatable, Sendable {
  public let sha256: String
  public let byteCount: Int

  public init(sha256: String, byteCount: Int) {
    self.sha256 = sha256
    self.byteCount = byteCount
  }

  public static func digest(of data: Data) -> SecureFileRevision {
    let digest = SHA256.hash(data: data)
    return SecureFileRevision(
      sha256: digest.map { String(format: "%02x", $0) }.joined(),
      byteCount: data.count
    )
  }
}

public enum SecureWriteMode: Equatable, Sendable {
  case create
  case replace
}

public struct SecureWriteResult: Equatable, Sendable {
  public let mode: SecureWriteMode
  public let oldRevision: SecureFileRevision?
  public let newRevision: SecureFileRevision
}

public struct SecureFileWriterStats: Sendable {
  public let openedRoot: Int32
  public let parentDescriptor: Int32
  public let targetDescriptor: Int32

  public init(openedRoot: Int32, parentDescriptor: Int32, targetDescriptor: Int32) {
    self.openedRoot = openedRoot
    self.parentDescriptor = parentDescriptor
    self.targetDescriptor = targetDescriptor
  }
}

public struct SecureProjectFileWriter: Sendable {
  public let maximumBytes: Int

  public init(maximumBytes: Int = 200 * 1_024) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func write(
    relativePath: SecureRelativePath,
    through resolver: ProjectPathResolver,
    mode: SecureWriteMode,
    content: Data,
    expectedSHA256: String?,
    createParents: Bool
  ) throws -> SecureWriteResult {
    guard content.count <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    guard String(data: content, encoding: .utf8) != nil, !content.contains(0) else {
      throw PathSecurityError.binaryFileBlocked
    }
    try resolver.root.validateCurrentIdentity()
    guard resolver.sensitivePolicy.allows(relativePath) else {
      throw PathSecurityError.sensitiveFileBlocked
    }

    var rootFD = open(
      resolver.root.canonicalPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootFD >= 0 else { throw PathSecurityError.writeFailed(errno) }
    do {
      try validateRootDescriptor(rootFD, root: resolver.root)
      let components = relativePath.components
      guard !components.isEmpty else { throw PathSecurityError.invalidRelativePath("empty path") }
      let parentFD = try openParentDirectory(
        components: components.dropLast(),
        rootFD: rootFD,
        createParents: createParents,
        resolver: resolver
      )
      defer { closeFD(parentFD) }
      let name = components[components.count - 1]
      switch mode {
      case .create:
        return try create(
          name: name,
          parentFD: parentFD,
          content: content,
          root: resolver.root
        )
      case .replace:
        return try replace(
          name: name,
          parentFD: parentFD,
          content: content,
          expectedSHA256: expectedSHA256,
          root: resolver.root
        )
      }
    } catch {
      if rootFD >= 0 { close(rootFD) }
      rootFD = -1
      throw error
    }
  }

  public func revision(
    relativePath: SecureRelativePath,
    through resolver: ProjectPathResolver
  ) throws -> SecureFileRevision? {
    try resolver.root.validateCurrentIdentity()
    guard resolver.sensitivePolicy.allows(relativePath) else {
      throw PathSecurityError.sensitiveFileBlocked
    }
    let rootFD = open(
      resolver.root.canonicalPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootFD >= 0 else { throw PathSecurityError.readFailed(errno) }
    defer { close(rootFD) }
    try validateRootDescriptor(rootFD, root: resolver.root)

    var current = rootFD
    for (index, component) in relativePath.components.enumerated() {
      let isLast = index == relativePath.components.count - 1
      let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY)
      let next = component.withCString { openat(current, $0, flags) }
      let openError = errno
      if current != rootFD { close(current) }
      current = -1
      guard next >= 0 else {
        if openError == ENOENT || openError == ENOTDIR { return nil }
        throw PathSecurityError.readFailed(openError)
      }
      current = next
    }
    defer { close(current) }
    let metadata = try validateRegularDescriptor(current, root: resolver.root)
    guard metadata.st_size <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    let data = try readFull(descriptor: current, maximumBytes: maximumBytes)
    return .digest(of: data)
  }

  private func create(
    name: String,
    parentFD: Int32,
    content: Data,
    root: RegisteredRoot
  ) throws -> SecureWriteResult {
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    var created = name.withCString { openat(parentFD, $0, flags, 0o644) }
    guard created >= 0 else {
      if errno == EEXIST { throw PathSecurityError.targetAlreadyExists }
      throw PathSecurityError.writeFailed(errno)
    }
    do {
      let metadata = try validateRegularDescriptor(created, root: root)
      _ = metadata
      try writeAll(created, data: content)
      guard fsync(created) == 0 else { throw PathSecurityError.writeFailed(errno) }
      close(created)
      created = -1
      guard fsync(parentFD) == 0 else {
        throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
      }
      return SecureWriteResult(mode: .create, oldRevision: nil, newRevision: .digest(of: content))
    } catch {
      if created >= 0 {
        close(created)
        _ = name.withCString { unlinkat(parentFD, $0, 0) }
      }
      throw error
    }
  }

  private func replace(
    name: String,
    parentFD: Int32,
    content: Data,
    expectedSHA256: String?,
    root: RegisteredRoot
  ) throws -> SecureWriteResult {
    var target = name.withCString {
      openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard target >= 0 else {
      throw PathSecurityError.writeFailed(errno)
    }
    do {
      let metadata = try validateReplaceableTarget(target, root: root)
      guard metadata.st_size <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }
      let existing = try readFull(descriptor: target, maximumBytes: maximumBytes)
      let oldRevision = SecureFileRevision.digest(of: existing)
      if let expectedSHA256, expectedSHA256 != oldRevision.sha256 {
        throw PathSecurityError.revisionConflict
      }
      close(target)
      target = -1

      let staging = ".codexbridge.staging.\(UUID().uuidString.lowercased())"
      var staged = try stagingDescriptor(parentFD: parentFD, name: staging)
      do {
        try writeAll(staged, data: content)
        guard fsync(staged) == 0 else { throw PathSecurityError.writeFailed(errno) }
        close(staged)
        staged = -1
        guard renameat(parentFD, staging, parentFD, name) == 0 else {
          throw PathSecurityError.writeFailed(errno)
        }
        guard fsync(parentFD) == 0 else {
          throw PathSecurityError.mutationAppliedDurabilityUncertain(errno)
        }
      } catch {
        if staged >= 0 {
          close(staged)
          _ = staging.withCString { unlinkat(parentFD, $0, 0) }
        }
        throw error
      }
      try verifyFinalContent(
        name: name,
        parentFD: parentFD,
        expectedRevision: .digest(of: content),
        root: root
      )
      return SecureWriteResult(
        mode: .replace,
        oldRevision: oldRevision,
        newRevision: .digest(of: content)
      )
    } catch {
      if target >= 0 { close(target) }
      throw error
    }
  }

  private func stagingDescriptor(parentFD: Int32, name: String) throws -> Int32 {
    for _ in 0..<8 {
      let candidate = name.isEmpty ? ".codexbridge.staging.\(UUID().uuidString.lowercased())" : name
      let descriptor = candidate.withCString {
        openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      }
      if descriptor >= 0 { return descriptor }
      if errno != EEXIST { throw PathSecurityError.writeFailed(errno) }
    }
    throw PathSecurityError.writeFailed(EEXIST)
  }

  private func verifyFinalContent(
    name: String,
    parentFD: Int32,
    expectedRevision: SecureFileRevision,
    root: RegisteredRoot
  ) throws {
    let reopened = name.withCString {
      openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard reopened >= 0 else { throw PathSecurityError.pathChanged }
    defer { close(reopened) }
    let metadata = try validateRegularDescriptor(reopened, root: root)
    guard metadata.st_size <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    let data = try readFull(descriptor: reopened, maximumBytes: maximumBytes)
    guard SecureFileRevision.digest(of: data) == expectedRevision else {
      throw PathSecurityError.pathChanged
    }
  }

  private func openParentDirectory(
    components: ArraySlice<String>,
    rootFD: Int32,
    createParents: Bool,
    resolver: ProjectPathResolver
  ) throws -> Int32 {
    var current = rootFD
    var currentIsRoot = true
    for component in components {
      var next = component.withCString {
        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      if next < 0, createParents, errno == ENOENT {
        guard mkdirat(current, component, 0o755) == 0 else {
          throw PathSecurityError.writeFailed(errno)
        }
        next = component.withCString {
          openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
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
      guard validateDirectoryDescriptor(next, root: resolver.root) else {
        close(next)
        throw PathSecurityError.pathEscapeBlocked
      }
      current = next
      currentIsRoot = false
    }
    if currentIsRoot {
      let duplicate = dup(rootFD)
      guard duplicate >= 0 else { throw PathSecurityError.writeFailed(errno) }
      return duplicate
    }
    return current
  }

  public func readContent(
    relativePath: SecureRelativePath,
    through resolver: ProjectPathResolver
  ) throws -> Data? {
    try resolver.root.validateCurrentIdentity()
    guard resolver.sensitivePolicy.allows(relativePath) else {
      throw PathSecurityError.sensitiveFileBlocked
    }
    let rootFD = open(
      resolver.root.canonicalPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootFD >= 0 else { throw PathSecurityError.readFailed(errno) }
    defer { close(rootFD) }
    try validateRootDescriptor(rootFD, root: resolver.root)

    var current = rootFD
    for (index, component) in relativePath.components.enumerated() {
      let isLast = index == relativePath.components.count - 1
      let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY)
      let next = component.withCString { openat(current, $0, flags) }
      let openError = errno
      if current != rootFD { close(current) }
      current = -1
      guard next >= 0 else {
        if openError == ENOENT || openError == ENOTDIR { return nil }
        throw PathSecurityError.readFailed(openError)
      }
      current = next
    }
    defer { close(current) }
    let metadata = try validateRegularDescriptor(current, root: resolver.root)
    guard metadata.st_size <= maximumBytes else {
      throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
    }
    return try readFull(descriptor: current, maximumBytes: maximumBytes)
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
    guard identity.device == root.identity.device else { return false }
    return true
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

  private func validateReplaceableTarget(_ descriptor: Int32, root: RegisteredRoot) throws -> stat {
    let metadata = try validateRegularDescriptor(descriptor, root: root)
    guard metadata.st_nlink <= 1 else {
      throw PathSecurityError.unsupportedHardLink
    }
    return metadata
  }

  private func writeAll(_ descriptor: Int32, data: Data) throws {
    var written = 0
    while written < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), data.count - written)
      }
      if count > 0 {
        written += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      throw PathSecurityError.writeFailed(errno)
    }
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

  private func closeFD(_ descriptor: Int32) {
    if descriptor >= 0 { close(descriptor) }
  }
}
