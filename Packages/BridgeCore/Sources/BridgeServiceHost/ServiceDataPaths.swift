import Foundation
#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

public enum ServiceDataPathsError: Error, Equatable, Sendable {
  case invalidRoot
  case insecureDirectory
  case systemFailure(Int32)
}

public struct ServiceDataPaths: Sendable {
  public let rootURL: URL
  public let databaseURL: URL
  public let supervisorScratchURL: URL
  public let agentStateURL: URL
  public let tunnelRuntimeURL: URL

  public init(
    rootURL: URL,
    databaseURL: URL,
    supervisorScratchURL: URL,
    tunnelRuntimeURL: URL,
    agentStateURL: URL? = nil
  ) {
    self.rootURL = rootURL
    self.databaseURL = databaseURL
    self.supervisorScratchURL = supervisorScratchURL
    self.tunnelRuntimeURL = tunnelRuntimeURL
    self.agentStateURL =
      agentStateURL
      ?? rootURL.appending(
        path: "AgentState",
        directoryHint: .isDirectory
      )
  }

  public static func prepare(at requestedRoot: URL) throws -> ServiceDataPaths {
    guard requestedRoot.isFileURL, isAcceptableRootPath(requestedRoot.path) else {
      throw ServiceDataPathsError.invalidRoot
    }
    let root = requestedRoot.standardizedFileURL
    try preparePrivateDirectory(root, createParents: true)
    let scratch = root.appending(
      path: "SupervisorScratch",
      directoryHint: .isDirectory
    )
    try preparePrivateDirectory(scratch, createParents: false)
    let agentState = root.appending(
      path: "AgentState",
      directoryHint: .isDirectory
    )
    try preparePrivateDirectory(agentState, createParents: false)
    let tunnelRuntime = root.appending(
      path: "TunnelRuntime",
      directoryHint: .isDirectory
    )
    try preparePrivateDirectory(tunnelRuntime, createParents: false)
    return ServiceDataPaths(
      rootURL: root,
      databaseURL: root.appending(path: "service.sqlite"),
      supervisorScratchURL: scratch,
      tunnelRuntimeURL: tunnelRuntime,
      agentStateURL: agentState
    )
  }

  public static func defaultRoot() -> URL {
    let fileManager = FileManager.default
    let parent =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appending(
        path: "Library/Application Support",
        directoryHint: .isDirectory
      )
    return parent.appending(path: "CodexBridgeService", directoryHint: .isDirectory)
  }

  private static func isAcceptableRootPath(_ path: String) -> Bool {
    #if os(Windows)
      if path.hasPrefix("\\\\") { return true }
      guard let first = path.first, first.isLetter, path.count >= 2 else { return false }
      return path[path.index(after: path.startIndex)] == ":"
    #else
      return path.hasPrefix("/")
    #endif
  }

  private static func preparePrivateDirectory(
    _ url: URL,
    createParents: Bool
  ) throws {
    #if os(Windows)
      // Windows enforces privacy through ACLs on the user profile; verifying
      // that the path is a real directory is the portable equivalent here.
      func currentAttributes() -> UInt32 {
        url.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
      }
      var attributes = currentAttributes()
      if attributes == INVALID_FILE_ATTRIBUTES {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: createParents
        )
        attributes = currentAttributes()
      }
      guard attributes != INVALID_FILE_ATTRIBUTES,
        attributes & UInt32(FILE_ATTRIBUTE_DIRECTORY) != 0,
        attributes & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw ServiceDataPathsError.insecureDirectory
      }
    #else
      var metadata = stat()
      if lstat(url.path, &metadata) != 0 {
        guard errno == ENOENT else { throw ServiceDataPathsError.systemFailure(errno) }
        do {
          try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: createParents,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
          )
          try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
          )
        } catch {
          throw ServiceDataPathsError.systemFailure(errno)
        }
        guard lstat(url.path, &metadata) == 0 else {
          throw ServiceDataPathsError.systemFailure(errno)
        }
      }
      guard metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else {
        throw ServiceDataPathsError.insecureDirectory
      }
    #endif
  }
}
