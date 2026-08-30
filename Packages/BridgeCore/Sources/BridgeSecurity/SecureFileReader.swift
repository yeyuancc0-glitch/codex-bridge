import Crypto
import Foundation
#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

public struct SecureTextFile: Equatable, Sendable {
  public let text: String
  public let bytesRead: Int
  public let lineCount: Int
  public let truncated: Bool
  public let sha256: String
  public let byteCount: Int

  public init(
    text: String,
    bytesRead: Int,
    lineCount: Int,
    truncated: Bool,
    sha256: String = "",
    byteCount: Int = 0
  ) {
    self.text = text
    self.bytesRead = bytesRead
    self.lineCount = lineCount
    self.truncated = truncated
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

public struct SecureFileReader: Sendable {
  public let maximumBytes: Int
  public let maximumLines: Int

  public init(maximumBytes: Int = 200 * 1024, maximumLines: Int = 300) {
    self.maximumBytes = max(1, maximumBytes)
    self.maximumLines = max(1, maximumLines)
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
    #if os(Windows)
      let components = try relativeComponents(of: resolved, root: root)
      try WindowsSecureFile.validateRootIdentity(root: root)
      let (handle, metadata) = try WindowsSecureFile.openResolving(
        rootPath: root.canonicalPath,
        components: components,
        desiredAccess: DWORD(GENERIC_READ),
        creationDisposition: DWORD(OPEN_EXISTING),
        finalIsDirectory: false
      )
      defer { WindowsSecureFile.close(handle) }
      guard metadata.identity == resolved.identity else {
        throw PathSecurityError.fileIdentityChanged
      }
      guard metadata.size <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }
      let data = try WindowsSecureFile.readFile(handle, maximumBytes: maximumBytes)
    #else
      let descriptor = try openDescriptor(for: resolved, root: root)
      defer { close(descriptor) }

      let metadata = try validateDescriptor(
        descriptor,
        root: root,
        expectedIdentity: resolved.identity
      )
      guard metadata.st_size <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }

      let data = try readBounded(descriptor)
    #endif
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

  #if !os(Windows)
    private func openDescriptor(
    for resolved: ResolvedProjectPath,
    root: RegisteredRoot
  ) throws -> Int32 {
    let relativePath = resolved.canonicalURL.path.dropFirst(root.canonicalPath.count)
      .drop(while: { $0 == "/" })
    let components = try SecureRelativePath(String(relativePath)).components

    var descriptor = open(
      root.canonicalPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw PathSecurityError.readFailed(errno) }

    do {
      try validateRootDescriptor(descriptor, root: root)
      for (index, component) in components.enumerated() {
        let isLast = index == components.count - 1
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY)
        let next = component.withCString { openat(descriptor, $0, flags) }
        let openError = errno
        close(descriptor)
        descriptor = -1
        guard next >= 0 else { throw PathSecurityError.readFailed(openError) }
        descriptor = next
      }
      return descriptor
    } catch {
      if descriptor >= 0 {
        close(descriptor)
      }
      throw error
    }
  }

  private func validateRootDescriptor(
    _ descriptor: Int32,
    root: RegisteredRoot
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw PathSecurityError.readFailed(errno)
    }
    let identity = FileSystemIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
    guard identity == root.identity else {
      throw PathSecurityError.rootIdentityChanged
    }
  }

  private func validateDescriptor(
    _ descriptor: Int32,
    root: RegisteredRoot,
    expectedIdentity: FileSystemIdentity
  ) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw PathSecurityError.readFailed(errno)
    }
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
    guard identity == expectedIdentity else {
      throw PathSecurityError.fileIdentityChanged
    }
    return metadata
  }

  private func readBounded(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumBytes + 1))

    while result.count <= maximumBytes {
      let requested = min(buffer.count, maximumBytes + 1 - result.count)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requested)
      }
      if count == 0 { return result }
      guard count > 0 else { throw PathSecurityError.readFailed(errno) }
      result.append(contentsOf: buffer.prefix(count))
    }
    throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
  }

  #endif
}

#if os(Windows)
extension SecureFileReader {
    private func relativeComponents(
      of resolved: ResolvedProjectPath,
      root: RegisteredRoot
    ) throws -> [String] {
      let relativePath = resolved.canonicalURL.path.dropFirst(root.canonicalPath.count)
        .drop(while: { $0 == "/" })
      return try SecureRelativePath(String(relativePath)).components
    }
}
#endif
