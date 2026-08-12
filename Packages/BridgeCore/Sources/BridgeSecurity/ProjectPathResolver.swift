import Foundation

public struct ResolvedProjectPath: Equatable, Sendable {
  public let requested: SecureRelativePath
  public let canonicalURL: URL
  public let identity: FileSystemIdentity

  public init(
    requested: SecureRelativePath,
    canonicalURL: URL,
    identity: FileSystemIdentity
  ) {
    self.requested = requested
    self.canonicalURL = canonicalURL
    self.identity = identity
  }
}

public struct ProjectPathResolver: Sendable {
  public let root: RegisteredRoot
  public let sensitivePolicy: SensitivePathPolicy

  public init(root: RegisteredRoot, sensitivePolicy: SensitivePathPolicy = .init()) {
    self.root = root
    self.sensitivePolicy = sensitivePolicy
  }

  public func resolve(_ relativePath: SecureRelativePath) throws -> ResolvedProjectPath {
    try root.validateCurrentIdentity()
    guard sensitivePolicy.allows(relativePath) else {
      throw PathSecurityError.sensitiveFileBlocked
    }

    let requestedURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
      .appending(path: relativePath.value)
    guard FileManager.default.fileExists(atPath: requestedURL.path) else {
      throw PathSecurityError.pathDoesNotExist
    }

    let canonicalURL = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
    guard contains(canonicalURL.path) else {
      throw PathSecurityError.pathEscapeBlocked
    }

    let canonicalRelative = try relativePathForResolvedURL(canonicalURL)
    guard sensitivePolicy.allows(canonicalRelative) else {
      throw PathSecurityError.sensitiveFileBlocked
    }
    return ResolvedProjectPath(
      requested: relativePath,
      canonicalURL: canonicalURL,
      identity: try RegisteredRoot.readIdentity(atPath: canonicalURL.path)
    )
  }

  private func contains(_ candidate: String) -> Bool {
    candidate == root.canonicalPath || candidate.hasPrefix(root.canonicalPath + "/")
  }

  private func relativePathForResolvedURL(_ url: URL) throws -> SecureRelativePath {
    let start = url.path.index(url.path.startIndex, offsetBy: root.canonicalPath.count)
    let suffix = url.path[start...].drop(while: { $0 == "/" })
    guard !suffix.isEmpty else {
      throw PathSecurityError.unsupportedFileType
    }
    return try SecureRelativePath(String(suffix))
  }
}
