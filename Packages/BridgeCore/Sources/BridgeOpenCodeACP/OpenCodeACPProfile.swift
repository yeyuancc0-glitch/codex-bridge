import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum OpenCodeACPProfiles {
  public static let controlledReadOnly = AgentProfileID(rawValue: "controlled-readonly")
}

public struct OpenCodeACPSemanticVersion: Comparable, Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(_ value: String) {
    let core = value.split(separator: "+", maxSplits: 1).first?
      .split(separator: "-", maxSplits: 1).first
    guard let core else { return nil }
    let components = core.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2]),
      major >= 0,
      minor >= 0,
      patch >= 0
    else { return nil }
    self.init(major: major, minor: minor, patch: patch)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }
}

public struct OpenCodeACPCompatibility: Equatable, Sendable {
  public let minimumVersion: OpenCodeACPSemanticVersion
  public let maximumExclusiveVersion: OpenCodeACPSemanticVersion

  public init(
    minimumVersion: OpenCodeACPSemanticVersion = .init(major: 1, minor: 18, patch: 20),
    maximumExclusiveVersion: OpenCodeACPSemanticVersion = .init(
      major: 1,
      minor: 19,
      patch: 0
    )
  ) {
    self.minimumVersion = minimumVersion
    self.maximumExclusiveVersion = maximumExclusiveVersion
  }

  public func accepts(version: String) -> Bool {
    guard let parsed = OpenCodeACPSemanticVersion(version) else { return false }
    return parsed >= minimumVersion && parsed < maximumExclusiveVersion
  }
}

public struct OpenCodeACPLaunchConfiguration: Sendable {
  public let process: OpenCodeACPProcessTransportConfiguration
  public let runDirectory: String
  public let resolvedExecutablePath: String

  public init(
    process: OpenCodeACPProcessTransportConfiguration,
    runDirectory: String,
    resolvedExecutablePath: String
  ) {
    self.process = process
    self.runDirectory = runDirectory
    self.resolvedExecutablePath = resolvedExecutablePath
  }
}

public struct OpenCodeACPLaunchBuilder: Sendable {
  public let sandboxExecutablePath: String
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration

  public init(
    sandboxExecutablePath: String = "/usr/bin/sandbox-exec",
    maximumFrameBytes: Int = 1_048_576,
    maximumStandardErrorBytes: Int = 256 * 1_024,
    maximumLifetime: Duration = .seconds(24 * 60 * 60)
  ) {
    self.sandboxExecutablePath = sandboxExecutablePath
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
  }

  public func make(
    installation: AgentInstallation,
    projectRoot: String,
    runDirectory: String,
    networkAllowed: Bool,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> OpenCodeACPLaunchConfiguration {
    guard installation.providerID == .openCode else {
      throw AgentRuntimeError.invalidRequest("installation.providerID")
    }
    let executable = try Self.resolveExecutable(installation.executablePath)
    let project = try Self.canonicalExistingDirectory(projectRoot, field: "projectRoot")
    let runtime = try Self.prepareRunDirectory(runDirectory)
    let environment = try Self.environment(
      executable: executable,
      runDirectory: runtime,
      networkAllowed: networkAllowed,
      source: sourceEnvironment
    )
    let writableRoots = try Self.writableRoots(environment: environment, runDirectory: runtime)
    guard !writableRoots.contains(where: { Self.pathsOverlap(project, $0) }) else {
      throw AgentRuntimeError.invalidRequest("projectRoot.runtimeOverlap")
    }
    guard let sandboxExecutable = Self.safeExecutable(sandboxExecutablePath) else {
      throw AgentRuntimeError.processUnavailable
    }

    let profile = try Self.sandboxProfile(
      projectRoot: project,
      writableRoots: writableRoots,
      networkAllowed: networkAllowed
    )
    let argv = [
      sandboxExecutable,
      "-p",
      profile,
      "--",
      executable,
      "--pure",
      "acp",
    ]
    return OpenCodeACPLaunchConfiguration(
      process: OpenCodeACPProcessTransportConfiguration(
        argv: argv,
        workingDirectory: project,
        environment: environment,
        maximumFrameBytes: maximumFrameBytes,
        maximumStandardErrorBytes: maximumStandardErrorBytes,
        maximumLifetime: maximumLifetime
      ),
      runDirectory: runtime,
      resolvedExecutablePath: executable
    )
  }

  public static func readOnlyPermissionJSON(networkAllowed: Bool) -> String {
    let policy: [String: Any] = [
      "*": "ask",
      "read": "allow",
      "glob": "allow",
      "grep": "allow",
      "list": "allow",
      "edit": "deny",
      "bash": "deny",
      "task": "deny",
      "external_directory": "deny",
      "todowrite": "allow",
      "question": "deny",
      "webfetch": networkAllowed ? "allow" : "deny",
      "websearch": networkAllowed ? "allow" : "deny",
      "lsp": "deny",
      "doom_loop": "deny",
      "skill": "deny",
    ]
    guard JSONSerialization.isValidJSONObject(policy),
      let data = try? JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]),
      let value = String(data: data, encoding: .utf8)
    else {
      preconditionFailure("Static OpenCode permission policy must be valid JSON.")
    }
    return value
  }

  static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  private static func environment(
    executable: String,
    runDirectory: String,
    networkAllowed: Bool,
    source: [String: String]
  ) throws -> [String: String] {
    let sourceHome = try absoluteEnvironmentPath(
      source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
      field: "environment.sourceHOME"
    )
    let dataHome = try absoluteEnvironmentPath(
      source["XDG_DATA_HOME"]
        ?? URL(fileURLWithPath: sourceHome).appendingPathComponent(".local/share").path,
      field: "environment.XDG_DATA_HOME"
    )
    let configHome = try absoluteEnvironmentPath(
      source["XDG_CONFIG_HOME"]
        ?? URL(fileURLWithPath: sourceHome).appendingPathComponent(".config").path,
      field: "environment.XDG_CONFIG_HOME"
    )
    let home = URL(fileURLWithPath: runDirectory).appendingPathComponent("home").path
    let cache = URL(fileURLWithPath: runDirectory).appendingPathComponent("cache").path
    let state = URL(fileURLWithPath: runDirectory).appendingPathComponent("state").path
    let temporary = URL(fileURLWithPath: runDirectory).appendingPathComponent("tmp").path
    let database = URL(fileURLWithPath: runDirectory).appendingPathComponent("opencode.db").path
    for path in [home, cache, state, temporary] {
      try createPrivateDirectory(path)
    }

    var environment: [String: String] = [
      "HOME": home,
      "PATH": trustedPath(executable: executable),
      "TMPDIR": temporary,
      "XDG_CONFIG_HOME": configHome,
      "XDG_CACHE_HOME": cache,
      "XDG_STATE_HOME": state,
      "XDG_DATA_HOME": dataHome,
      "OPENCODE_CLIENT": "codex-bridge",
      "OPENCODE_AUTO_SHARE": "false",
      "OPENCODE_DISABLE_AUTOUPDATE": "1",
      "OPENCODE_DISABLE_CLAUDE_CODE": "1",
      "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
      "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
      "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
      "OPENCODE_DISABLE_TERMINAL_TITLE": "1",
      "OPENCODE_DB": database,
      "OPENCODE_ENABLE_EXA": "false",
      "OPENCODE_EXPERIMENTAL": "false",
      "OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER": "1",
      "OPENCODE_PERMISSION": readOnlyPermissionJSON(networkAllowed: networkAllowed),
      "GIT_OPTIONAL_LOCKS": "0",
      "NO_COLOR": "1",
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"] {
      if let value = source[key], !value.isEmpty, !value.contains("\0") {
        environment[key] = value
      }
    }
    return environment
  }

  private static func writableRoots(
    environment: [String: String],
    runDirectory: String
  ) throws -> [String] {
    guard let dataHome = environment["XDG_DATA_HOME"] else {
      throw AgentRuntimeError.invalidRequest("environment.XDG_DATA_HOME")
    }
    let logDirectory = URL(fileURLWithPath: dataHome)
      .appendingPathComponent("opencode/log", isDirectory: true).path
    return try [runDirectory, logDirectory].map {
      try canonicalPathAllowingMissingLeaf($0, field: "sandbox.writableRoot")
    }
  }

  private static func sandboxProfile(
    projectRoot: String,
    writableRoots: [String],
    networkAllowed: Bool
  ) throws -> String {
    var rules = ["(version 1)", "(allow default)"]
    let isProbe = isTemporaryProbeProject(projectRoot, writableRoots: writableRoots)
    // OpenCode's ACP runtime needs local networking that seatbelt cannot
    // separate from tool networking; tool-level network stays governed by
    // OPENCODE_PERMISSION, so no sandbox-level network deny here.
    // Seatbelt matches canonical paths (/var → /private/var), so every rule
    // path must go through realpath or the allow never matches.
    var allowedWriteRoots = writableRoots.map(Self.resolvedSandboxPath)
    // System temporary directory is needed for Node/Bun temp files.
    for tmp in ["/tmp", "/private/tmp", FileManager.default.temporaryDirectory.path] {
      allowedWriteRoots.append(Self.resolvedSandboxPath(tmp))
    }
    // Probe runs use a temporary project directory that must remain writable.
    if isProbe {
      allowedWriteRoots.append(Self.resolvedSandboxPath(projectRoot))
    }
    rules.append(
      try denyWritesOutside(
        roots: Array(Set(allowedWriteRoots)).sorted(),
        literalPaths: ["/dev/null"]
      )
    )
    if !isProbe {
      let resolvedProject = Self.resolvedSandboxPath(projectRoot)
      rules.append(
        "(deny file-write* (literal \"\(try sandboxLiteral(resolvedProject))\"))"
      )
      rules.append(
        "(deny file-write* (subpath \"\(try sandboxLiteral(resolvedProject))\"))"
      )
    }
    return rules.joined()
  }

  private static func denyWritesOutside(
    roots: [String],
    literalPaths: [String]
  ) throws -> String {
    let rootRequirements = try roots.map {
      "(require-not (subpath \"\(try sandboxLiteral($0))\"))"
    }
    let literalRequirements = try literalPaths.map {
      "(require-not (literal \"\(try sandboxLiteral($0))\"))"
    }
    return "(deny file-write* (require-all \((rootRequirements + literalRequirements).joined())))"
  }

  private static func resolvedSandboxPath(_ path: String) -> String {
    var buffer = [Int8](repeating: 0, count: 16_384)
    guard realpath(path, &buffer) != nil else { return path }
    return String(cString: buffer)
  }

  private static func isTemporaryProbeProject(
    _ projectRoot: String,
    writableRoots: [String]
  ) -> Bool {
    let standardized = URL(fileURLWithPath: projectRoot).standardized.path
    // Inside any writable root (e.g. run directory) is already allowed.
    for root in writableRoots {
      let canonicalRoot = URL(fileURLWithPath: root).standardized.path
      if standardized == canonicalRoot || standardized.hasPrefix(canonicalRoot + "/") {
        return true
      }
    }
    // Probe projects are created as siblings of the run directory with a
    // distinct prefix inside the same runtime base.
    if let firstRoot = writableRoots.first {
      let runtimeBase = URL(fileURLWithPath: firstRoot).deletingLastPathComponent()
        .standardized.path
      if standardized.hasPrefix(runtimeBase + "/") {
        let relative = String(standardized.dropFirst(runtimeBase.count + 1))
        let firstComponent =
          relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if firstComponent.hasPrefix("probe-") {
          return true
        }
      }
    }
    return false
  }

  private static func trustedPath(executable: String) -> String {
    let candidates = [
      URL(fileURLWithPath: executable).deletingLastPathComponent().path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }.joined(separator: ":")
  }

  private static func resolveExecutable(_ path: String) throws -> String {
    guard let resolved = safeExecutable(path) else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    return resolved
  }

  private static func safeExecutable(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      return nil
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
    return resolved
  }

  private static func canonicalExistingDirectory(_ path: String, field: String) throws -> String {
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

  private static func prepareRunDirectory(_ path: String) throws -> String {
    let canonical = try canonicalPathAllowingMissingLeaf(path, field: "runDirectory")
    try createPrivateDirectory(canonical)
    return URL(fileURLWithPath: canonical).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func canonicalPathAllowingMissingLeaf(_ path: String, field: String) throws
    -> String
  {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func createPrivateDirectory(_ path: String) throws {
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
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

  private static func pathsOverlap(_ first: String, _ second: String) -> Bool {
    contains(first, second) || contains(second, first)
  }

  private static func contains(_ root: String, _ candidate: String) -> Bool {
    if root == candidate { return true }
    let prefix = root == "/" ? "/" : root + "/"
    return candidate.hasPrefix(prefix)
  }

  private static func sandboxLiteral(_ value: String) throws -> String {
    guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
      throw AgentRuntimeError.invalidRequest("sandbox.path")
    }
    return value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
