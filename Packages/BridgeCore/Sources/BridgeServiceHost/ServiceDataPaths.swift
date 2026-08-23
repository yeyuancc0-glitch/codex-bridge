import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(WinSDK)
  import BridgePlatformWindows
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
  public let tunnelRuntimeURL: URL

  public init(
    rootURL: URL,
    databaseURL: URL,
    supervisorScratchURL: URL,
    tunnelRuntimeURL: URL
  ) {
    self.rootURL = rootURL
    self.databaseURL = databaseURL
    self.supervisorScratchURL = supervisorScratchURL
    self.tunnelRuntimeURL = tunnelRuntimeURL
  }

  public static func prepare(at requestedRoot: URL) throws -> ServiceDataPaths {
    #if canImport(WinSDK)
      do {
        let paths = try WindowsServicePaths.prepare(at: requestedRoot)
        return ServiceDataPaths(
          rootURL: paths.rootURL,
          databaseURL: paths.databaseURL,
          supervisorScratchURL: paths.supervisorScratchURL,
          tunnelRuntimeURL: paths.tunnelRuntimeURL
        )
      } catch WindowsServicePaths.PathsError.invalidRoot {
        throw ServiceDataPathsError.invalidRoot
      } catch WindowsServicePaths.PathsError.insecureDirectory {
        throw ServiceDataPathsError.insecureDirectory
      } catch WindowsServicePaths.PathsError.unavailable(let code) {
        throw ServiceDataPathsError.systemFailure(code)
      }
    #else
      guard requestedRoot.isFileURL, requestedRoot.path.hasPrefix("/") else {
        throw ServiceDataPathsError.invalidRoot
      }
      let root = requestedRoot.standardizedFileURL
      try preparePrivateDirectory(root, createParents: true)
      let scratch = root.appending(
        path: "SupervisorScratch",
        directoryHint: .isDirectory
      )
      try preparePrivateDirectory(scratch, createParents: false)
      let tunnelRuntime = root.appending(
        path: "TunnelRuntime",
        directoryHint: .isDirectory
      )
      try preparePrivateDirectory(tunnelRuntime, createParents: false)
      return ServiceDataPaths(
        rootURL: root,
        databaseURL: root.appending(path: "service.sqlite"),
        supervisorScratchURL: scratch,
        tunnelRuntimeURL: tunnelRuntime
      )
    #endif
  }

  public static func defaultRoot() -> URL {
    #if canImport(WinSDK)
      return WindowsServicePaths.defaultRoot()
    #else
      let fileManager = FileManager.default
      let parent =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appending(
          path: "Library/Application Support",
          directoryHint: .isDirectory
        )
      return parent.appending(path: "CodexBridgeService", directoryHint: .isDirectory)
    #endif
  }

  #if canImport(Darwin)
    private static func preparePrivateDirectory(
      _ url: URL,
      createParents: Bool
    ) throws {
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
    }
  #endif
}
