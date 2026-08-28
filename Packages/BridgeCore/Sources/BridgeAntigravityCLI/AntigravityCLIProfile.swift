import BridgeAgentCore
import BridgeProcess
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum AntigravityCLIProfiles {
  /// Uses the user's Antigravity CLI home, settings, and cached credentials.
  /// Desktop and CLI authentication are not assumed to be interchangeable.
  public static let desktopShared = AgentProfileID(rawValue: "desktop-shared")
}

public struct AntigravityCLISemanticVersion: Comparable, Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(_ output: String) {
    let candidates = output.split { !$0.isNumber && $0 != "." }
    guard
      let candidate = candidates.first(where: {
        $0.split(separator: ".", omittingEmptySubsequences: false).count == 3
      })
    else { return nil }
    let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
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

  public var stringValue: String { "\(major).\(minor).\(patch)" }
}

public struct AntigravityCLICompatibility: Equatable, Sendable {
  public let minimumVersion: AntigravityCLISemanticVersion
  public let maximumExclusiveVersion: AntigravityCLISemanticVersion

  public init(
    minimumVersion: AntigravityCLISemanticVersion = .init(major: 1, minor: 1, patch: 21),
    maximumExclusiveVersion: AntigravityCLISemanticVersion = .init(major: 1, minor: 2, patch: 0)
  ) {
    self.minimumVersion = minimumVersion
    self.maximumExclusiveVersion = maximumExclusiveVersion
  }

  public func accepts(_ version: AntigravityCLISemanticVersion) -> Bool {
    version >= minimumVersion && version < maximumExclusiveVersion
  }
}

struct AntigravityCLIHelpFacts: Equatable, Sendable {
  let supportsStreamJSON: Bool
  let supportsPlanMode: Bool
  let supportsAcceptEditsMode: Bool
  let supportsConversation: Bool
  let supportsModel: Bool
  let supportsEffort: Bool
  let supportsQueuedTurns: Bool

  var observedCapabilities: Set<AgentCapability> {
    var result: Set<AgentCapability> = []
    if supportsStreamJSON {
      result.insert(.sessionCreate)
    }
    if supportsPlanMode && supportsStreamJSON {
      result.insert(.workspaceRead)
    }
    if supportsAcceptEditsMode && supportsStreamJSON {
      result.insert(.workspaceWriteInPlace)
    }
    if supportsConversation {
      result.insert(.sessionContinue)
    }
    if supportsModel {
      result.insert(.modelSelection)
    }
    if supportsEffort {
      result.insert(.effortSelection)
    }
    if supportsQueuedTurns {
      result.insert(.steer)
    }
    return result
  }

  static func parse(_ output: String) -> Self {
    let plain = output.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*m",
      with: "",
      options: .regularExpression
    )
    let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    let inputLine = lines.first(where: { $0.contains("--input-format") }) ?? ""
    let outputLine = lines.first(where: { $0.contains("--output-format") }) ?? ""
    let modeLine = lines.first(where: { $0.contains("--mode") }) ?? ""
    let effortLine = lines.first(where: { $0.contains("--effort") }) ?? ""
    let streamJSON = inputLine.contains("stream-json") && outputLine.contains("stream-json")
    let queuedTurns = inputLine.contains("runs a turn for each")
    return Self(
      supportsStreamJSON: streamJSON,
      supportsPlanMode: modeLine.contains("plan"),
      supportsAcceptEditsMode: modeLine.contains("accept-edits"),
      supportsConversation: lines.contains(where: { $0.contains("--conversation") }),
      supportsModel: lines.contains(where: { $0.contains("--model") }),
      supportsEffort: effortLine.contains("--effort")
        && ["low", "medium", "high"].allSatisfy(effortLine.contains),
      supportsQueuedTurns: streamJSON && queuedTurns
    )
  }
}

public struct AntigravityCLICommandResult: Equatable, Sendable {
  public let standardOutput: BoundedProcessOutput
  public let standardError: BoundedProcessOutput
  public let termination: ManagedProcessTermination
  public let timedOut: Bool

  public init(
    standardOutput: BoundedProcessOutput,
    standardError: BoundedProcessOutput,
    termination: ManagedProcessTermination,
    timedOut: Bool
  ) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.termination = termination
    self.timedOut = timedOut
  }
}

public protocol AntigravityCLICommandRunning: Sendable {
  func run(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    timeout: Duration
  ) async throws -> AntigravityCLICommandResult
}

public struct AntigravityCLICommandRunner: AntigravityCLICommandRunning, Sendable {
  public let maximumOutputBytes: Int

  public init(maximumOutputBytes: Int = 1_048_576) {
    self.maximumOutputBytes = max(1, maximumOutputBytes)
  }

  public func run(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    timeout: Duration
  ) async throws -> AntigravityCLICommandResult {
    let output = BoundedProcessOutputCollector(maximumBytes: maximumOutputBytes)
    let error = BoundedProcessOutputCollector(maximumBytes: maximumOutputBytes)
    let process: ManagedStdioProcess
    do {
      process = try ManagedStdioProcess(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        mergeStandardError: false,
        onStandardOutput: { output.append($0) },
        onStandardError: { error.append($0) }
      )
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
    process.closeStdin()
    let result = await ManagedProcessRunner(defaultTimeout: timeout).monitor(process: process)
    return AntigravityCLICommandResult(
      standardOutput: output.snapshot(),
      standardError: error.snapshot(),
      termination: result.termination,
      timedOut: result.timedOut
    )
  }
}

public struct AntigravityCLIProcessConfiguration: Sendable {
  public let argv: [String]
  public let workingDirectory: String
  public let environment: [String: String]
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration
  public let standardInputTimeout: Duration

  public init(
    argv: [String],
    workingDirectory: String,
    environment: [String: String],
    maximumFrameBytes: Int,
    maximumStandardErrorBytes: Int,
    maximumLifetime: Duration,
    standardInputTimeout: Duration = .seconds(2)
  ) {
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumStandardErrorBytes = maximumStandardErrorBytes
    self.maximumLifetime = maximumLifetime
    self.standardInputTimeout = standardInputTimeout
  }
}

public struct AntigravityCLILaunchConfiguration: Sendable {
  public let process: AntigravityCLIProcessConfiguration
  public let runDirectory: String
  public let resolvedExecutablePath: String
  public let readOnlySandboxed: Bool

  public init(
    process: AntigravityCLIProcessConfiguration,
    runDirectory: String,
    resolvedExecutablePath: String,
    readOnlySandboxed: Bool
  ) {
    self.process = process
    self.runDirectory = runDirectory
    self.resolvedExecutablePath = resolvedExecutablePath
    self.readOnlySandboxed = readOnlySandboxed
  }
}

public struct AntigravityCLILaunchBuilder: Sendable {
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration
  public let sandboxExecutablePath: String

  public init(
    maximumFrameBytes: Int = 1_048_576,
    maximumStandardErrorBytes: Int = 256 * 1_024,
    maximumLifetime: Duration = .seconds(24 * 60 * 60),
    sandboxExecutablePath: String = "/usr/bin/sandbox-exec"
  ) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
    self.sandboxExecutablePath = sandboxExecutablePath
  }

  public func make(
    installation: AgentInstallation,
    request: AgentExecutionRequest,
    runDirectory: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AntigravityCLILaunchConfiguration {
    guard installation.providerID == .antigravity else {
      throw AgentRuntimeError.invalidRequest("installation.providerID")
    }
    let expectedStrategy: AgentWorkspaceStrategy =
      request.mutationIntent == .readOnly ? .sharedProject : .exclusiveProject
    guard request.workspaceStrategy == expectedStrategy else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    let executable = try Self.resolveExecutable(installation.executablePath)
    let projectRoot = try Self.canonicalExistingDirectory(
      request.projectRoot,
      field: "request.projectRoot"
    )
    let runtime = try Self.preparePrivateDirectory(runDirectory)
    let environment = try Self.environment(
      executable: executable,
      runDirectory: runtime,
      source: sourceEnvironment
    )
    var providerArgv = [
      executable,
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
    ]
    let readOnly = request.mutationIntent == .readOnly
    providerArgv.append(contentsOf: ["--mode", readOnly ? "plan" : "accept-edits"])
    if let sessionID = request.requestedSessionID {
      providerArgv.append(contentsOf: ["--conversation", sessionID])
    }
    if let model = request.model {
      providerArgv.append(contentsOf: ["--model", model])
    }
    if let effort = request.effort {
      guard ["low", "medium", "high"].contains(effort) else {
        throw AgentRuntimeError.invalidRequest("request.effort")
      }
      providerArgv.append(contentsOf: ["--effort", effort])
    }

    guard FileManager.default.isExecutableFile(atPath: sandboxExecutablePath) else {
      throw AgentRuntimeError.processUnavailable
    }
    providerArgv.append(contentsOf: ["--add-dir", projectRoot])
    let profile = try Self.sandboxProfile(
      projectRoot: projectRoot,
      runDirectory: runtime,
      allowsWorkspaceWrites: !readOnly
    )
    let argv = [sandboxExecutablePath, "-p", profile, "--"] + providerArgv
    return AntigravityCLILaunchConfiguration(
      process: AntigravityCLIProcessConfiguration(
        argv: argv,
        workingDirectory: projectRoot,
        environment: environment,
        maximumFrameBytes: maximumFrameBytes,
        maximumStandardErrorBytes: maximumStandardErrorBytes,
        maximumLifetime: maximumLifetime,
        standardInputTimeout: .seconds(2)
      ),
      runDirectory: runtime,
      resolvedExecutablePath: executable,
      readOnlySandboxed: readOnly
    )
  }

  public func commandEnvironment(
    executablePath: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [String: String] {
    let executable = try Self.resolveExecutable(executablePath)
    return try Self.environment(
      executable: executable,
      runDirectory: sourceEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
      source: sourceEnvironment,
      prepareTemporaryDirectory: false
    )
  }

  public static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  private static func sandboxProfile(
    projectRoot: String,
    runDirectory: String,
    allowsWorkspaceWrites: Bool
  ) throws -> String {
    guard projectRoot.rangeOfCharacter(from: .controlCharacters) == nil,
      runDirectory.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest("request.projectRoot")
    }
    let escapedProjectRoot = escapedProfilePath(projectRoot)
    let escapedRunDirectory = escapedProfilePath(runDirectory)
    var profile =
      "(version 1)(allow default)(deny file-write*)"
      + "(allow file-write* (subpath \"\(escapedRunDirectory)\"))"
    if allowsWorkspaceWrites {
      profile += "(allow file-write* (subpath \"\(escapedProjectRoot)\"))"
    }
    return profile
  }

  private static func escapedProfilePath(_ path: String) -> String {
    path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private static func environment(
    executable: String,
    runDirectory: String,
    source: [String: String],
    prepareTemporaryDirectory: Bool = true
  ) throws -> [String: String] {
    let home = try absoluteEnvironmentPath(
      source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
      field: "environment.HOME"
    )
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
      "PATH": trustedPath(executable: executable),
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

  private static func preparePrivateDirectory(_ path: String) throws -> String {
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
