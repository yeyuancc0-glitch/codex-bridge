import BridgeAgentCore
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
    AgentPathSemantics.isContained(candidate, in: root.canonicalPath)
  }

  private func relativePathForResolvedURL(_ url: URL) throws -> SecureRelativePath {
    guard
      let relative = AgentPathSemantics.relativePath(
        url.path,
        from: root.canonicalPath
      )
    else {
      throw PathSecurityError.unsupportedFileType
    }
    let portable = relative.replacingOccurrences(of: "\\", with: "/")
    guard !portable.isEmpty else { throw PathSecurityError.unsupportedFileType }
    return try SecureRelativePath(portable)
  }
}
