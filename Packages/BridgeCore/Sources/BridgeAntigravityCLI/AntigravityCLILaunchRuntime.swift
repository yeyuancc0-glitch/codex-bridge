import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
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
        source: source
      ),
      "TMPDIR": temporary,
    ]
    #if os(Windows)
      environment["USERPROFILE"] = home
      environment["TEMP"] = temporary
      environment["TMP"] = temporary
      for key in [
        "SystemRoot", "SystemDrive", "ComSpec", "PATHEXT", "LOCALAPPDATA", "APPDATA",
      ] {
        if let value = source.first(where: {
          $0.key.caseInsensitiveCompare(key) == .orderedSame
        })?.value,
          !value.isEmpty,
          !value.contains("\0"),
          value.rangeOfCharacter(from: .controlCharacters) == nil
        {
          environment[key] = value
        }
      }
    #endif
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
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    #if os(Windows)
      guard let resolved = existingFilesystemPath(path) else {
        throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
      }
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
        attributes[.type] as? FileAttributeType == .typeRegular
      else {
        throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
      }
      return resolved
    #else
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
    #endif
  }

  static func canonicalExistingDirectory(_ path: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    #if os(Windows)
      guard let resolved = existingFilesystemPath(path) else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      return resolved
    #else
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      return resolved
    #endif
  }

  static func preparePrivateDirectory(
    _ path: String,
    field: String = "runDirectory"
  ) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    #if os(Windows)
      guard let requested = canonicalFoundationPath(path) else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      do {
        try FileManager.default.createDirectory(
          atPath: requested,
          withIntermediateDirectories: true
        )
        guard let resolved = existingFilesystemPath(requested),
          samePath(resolved, requested)
        else {
          throw AgentRuntimeError.processUnavailable
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
          isDirectory.boolValue
        else {
          throw AgentRuntimeError.processUnavailable
        }
        return resolved
      } catch let error as AgentRuntimeError {
        throw error
      } catch {
        throw AgentRuntimeError.processUnavailable
      }
    #else
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
    #endif
  }

  static func canonicalFoundationPath(_ path: String) -> String? {
    #if os(Windows)
      let normalized = normalizeFoundationPath(path)
      guard AgentPathSemantics.isAbsolute(normalized, style: .windows),
        let lexical = AgentPathSemantics.canonicalPath(normalized, style: .windows)
      else {
        return nil
      }
      let standardized = URL(fileURLWithPath: lexical).standardizedFileURL.path
      return AgentPathSemantics.canonicalPath(
        normalizeFoundationPath(standardized),
        style: .windows
      )
    #else
      URL(fileURLWithPath: path).standardizedFileURL.path
    #endif
  }

  #if os(Windows)
    static func normalizeFoundationPath(_ path: String) -> String {
      guard path.count > 3, path.first == "/" else { return path }
      let characters = Array(path)
      guard characters[2] == ":",
        characters[1].isASCII && characters[1].isLetter
      else {
        return path
      }
      return String(path.dropFirst())
    }

    private static func existingFilesystemPath(_ path: String) -> String? {
      guard let lexical = canonicalFoundationPath(path) else { return nil }
      let resolved = URL(fileURLWithPath: lexical)
        .resolvingSymlinksInPath().standardizedFileURL.path
      return canonicalFoundationPath(resolved)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
      AgentPathSemantics.isContained(lhs, in: rhs)
        && AgentPathSemantics.isContained(rhs, in: lhs)
    }
  #endif

  private static func absoluteEnvironmentPath(_ path: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    #if os(Windows)
      guard let resolved = existingFilesystemPath(path) else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      return resolved
    #else
      return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    #endif
  }
}
