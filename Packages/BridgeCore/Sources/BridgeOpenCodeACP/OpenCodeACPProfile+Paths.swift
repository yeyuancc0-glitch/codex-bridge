import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
#endif

enum OpenCodeACPPathSupport {
  static func canonicalFilesystemPath(
    _ path: String,
    isDirectory: Bool = false,
    resolvingSymlinks: Bool = true
  ) -> String? {
    let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
    let resolvedURL = resolvingSymlinks ? url.resolvingSymlinksInPath() : url
    let resolved = resolvedURL.standardizedFileURL.path
    #if os(Windows)
      return AgentPathSemantics.canonicalPath(
        normalizeFoundationPath(resolved),
        style: .windows
      )
    #else
      return AgentPathSemantics.canonicalPath(resolved, style: .posix)
    #endif
  }

  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.isContained(lhs, in: rhs)
      && AgentPathSemantics.isContained(rhs, in: lhs)
  }

  #if os(Windows)
    private static func normalizeFoundationPath(_ path: String) -> String {
      guard path.count > 3, path.first == "/" else { return path }
      let characters = Array(path)
      guard characters[2] == ":",
        characters[1].isASCII && characters[1].isLetter
      else {
        return path
      }
      return String(path.dropFirst())
    }
  #endif
}

extension OpenCodeACPLaunchBuilder {
  static func resolveExecutable(_ path: String) throws -> String {
    guard let resolved = safeExecutable(path) else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    return resolved
  }

  private static func safeExecutable(_ path: String) -> String? {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"), path.utf8.count <= 16 * 1_024
    else {
      return nil
    }
    guard let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(path) else { return nil }
    #if os(Windows)
      // Windows uses ACLs; only existence and regular-file type are portable checks.
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
        attributes[.type] as? FileAttributeType == .typeRegular
      else { return nil }
    #else
      var info = stat()
      guard stat(resolved, &info) == 0,
        (info.st_mode & S_IFMT) == S_IFREG,
        access(resolved, X_OK) == 0,
        info.st_uid == getuid() || info.st_uid == 0,
        (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0,
        (info.st_mode & mode_t(S_ISUID | S_ISGID)) == 0
      else {
        return nil
      }
    #endif
    return resolved
  }

  static func canonicalExistingDirectory(_ path: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"), path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    guard let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(path, isDirectory: true)
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return resolved
  }

  static func prepareRunDirectory(_ path: String) throws -> String {
    let canonical = try canonicalPathAllowingMissingLeaf(path, field: "runDirectory")
    try createPrivateDirectory(canonical)
    guard
      let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(
        canonical,
        isDirectory: true
      ),
      OpenCodeACPPathSupport.samePath(resolved, canonical)
    else {
      throw AgentRuntimeError.processUnavailable
    }
    return resolved
  }

  private static func canonicalPathAllowingMissingLeaf(_ path: String, field: String) throws
    -> String
  {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"), path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    #if os(Windows)
      let resolvingSymlinks = false
    #else
      let resolvingSymlinks = true
    #endif
    guard
      let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(
        path,
        isDirectory: true,
        resolvingSymlinks: resolvingSymlinks
      )
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return resolved
  }

  static func createPrivateDirectory(_ path: String) throws {
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: Self.privateDirectoryAttributes
      )
      #if os(Windows)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(
            path,
            isDirectory: true
          ),
          OpenCodeACPPathSupport.samePath(resolved, path)
        else {
          // Windows uses ACLs; Foundation creation retains the current user's ACL.
          throw AgentRuntimeError.processUnavailable
        }
      #else
        guard chmod(path, 0o700) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
          metadata.st_uid == getuid(),
          metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_mode & 0o777 == 0o700
        else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  static func absoluteEnvironmentPath(_ path: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"), path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    guard let resolved = OpenCodeACPPathSupport.canonicalFilesystemPath(path) else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return resolved
  }

  private static var privateDirectoryAttributes: [FileAttributeKey: Any]? {
    #if os(Windows)
      nil
    #else
      [.posixPermissions: 0o700]
    #endif
  }
}
