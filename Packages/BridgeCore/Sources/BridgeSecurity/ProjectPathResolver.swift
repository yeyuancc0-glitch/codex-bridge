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
    #if os(Windows)
      let rootPath = windowsNormalized(root.canonicalPath)
      let candidatePath = windowsNormalized(candidate)
      if candidatePath.caseInsensitiveCompare(rootPath) == .orderedSame { return true }
      return candidatePath.range(
        of: rootPath + "\\",
        options: [.anchored, .caseInsensitive]
      ) != nil
    #else
      return candidate == root.canonicalPath || candidate.hasPrefix(root.canonicalPath + "/")
    #endif
  }

  private func relativePathForResolvedURL(_ url: URL) throws -> SecureRelativePath {
    #if os(Windows)
      let rootPath = windowsNormalized(root.canonicalPath)
      let candidatePath = windowsNormalized(url.path)
      guard
        let rootRange = candidatePath.range(
          of: rootPath,
          options: [.anchored, .caseInsensitive]
        )
      else {
        throw PathSecurityError.pathEscapeBlocked
      }
      let suffix = candidatePath[rootRange.upperBound...].drop(while: { $0 == "\\" })
      guard !suffix.isEmpty else { throw PathSecurityError.unsupportedFileType }
      return try SecureRelativePath(String(suffix).replacingOccurrences(of: "\\", with: "/"))
    #else
      let start = url.path.index(url.path.startIndex, offsetBy: root.canonicalPath.count)
      let suffix = url.path[start...].drop(while: { $0 == "/" })
      guard !suffix.isEmpty else {
        throw PathSecurityError.unsupportedFileType
      }
      return try SecureRelativePath(String(suffix))
    #endif
  }

  #if os(Windows)
    private func windowsNormalized(_ path: String) -> String {
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
  #endif
}
