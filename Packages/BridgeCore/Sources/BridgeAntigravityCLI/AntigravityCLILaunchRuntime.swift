import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum AntigravityCLILaunchRuntime {
  static func environment(
    executable: String,
    runDirectory: String,
    source: [String: String],
    prepareTemporaryDirectory: Bool = true
  ) throws -> [String: String] {
    let home = try AgentProviderEnvironment.homeDirectory(source: source)
    let temporary: String
    if prepareTemporaryDirectory {
      temporary =
        URL(fileURLWithPath: runDirectory, isDirectory: true)
        .appendingPathComponent("tmp", isDirectory: true).path
      _ = try preparePrivateDirectory(temporary)
    } else {
      temporary = try absoluteEnvironmentPath(runDirectory, field: "environment.TMPDIR")
    }
    var environment: [String: String] = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: executable,
        sourcePath: source["PATH"]
      ),
      "TMPDIR": temporary,
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"] {
      if let value = source[key], !value.isEmpty, !value.contains("\0") {
        environment[key] = value
      }
    }
    for key in ["GEMINI_API_KEY", "GOOGLE_GEMINI_BASE_URL"] {
      if let value = source[key], !value.isEmpty, !value.contains("\0") {
        environment[key] = value
      }
    }
    return environment
  }

  static func resolveExecutable(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    var metadata = stat()
    guard stat(resolved, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      access(resolved, X_OK) == 0,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0
    else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    return resolved
  }

  static func canonicalExistingDirectory(_ path: String, field: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return resolved
  }

  static func preparePrivateDirectory(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runDirectory")
    }
    let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(requested, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      var metadata = stat()
      guard lstat(requested, &metadata) == 0,
        metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else {
        throw AgentRuntimeError.processUnavailable
      }
      return URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func absoluteEnvironmentPath(_ path: String, field: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
