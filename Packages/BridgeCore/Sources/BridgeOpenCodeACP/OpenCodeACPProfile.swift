import BridgeAgentCore
import Foundation

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
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration

  public init(
    maximumFrameBytes: Int = 1_048_576,
    maximumStandardErrorBytes: Int = 256 * 1_024,
    maximumLifetime: Duration = .seconds(24 * 60 * 60)
  ) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
  }

  public func make(
    installation: AgentInstallation,
    projectRoot: String,
    runDirectory: String,
    persistentStateDirectory: String? = nil,
    networkAllowed _: Bool,
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
      persistentStateDirectory: persistentStateDirectory,
      source: sourceEnvironment
    )
    let argv = [
      executable,
      "acp",
      "--cwd",
      project,
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

  static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  private static func environment(
    executable: String,
    runDirectory: String,
    persistentStateDirectory: String?,
    source: [String: String]
  ) throws -> [String: String] {
    let sourceHome = try AgentProviderEnvironment.homeDirectory(
      source: source,
      field: "environment.sourceHOME"
    )
    let dataHome = try absoluteEnvironmentPath(
      source["XDG_DATA_HOME"]
        ?? URL(fileURLWithPath: sourceHome)
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true).path,
      field: "environment.XDG_DATA_HOME"
    )
    let configHome = try absoluteEnvironmentPath(
      source["XDG_CONFIG_HOME"]
        ?? URL(fileURLWithPath: sourceHome)
        .appendingPathComponent(".config", isDirectory: true).path,
      field: "environment.XDG_CONFIG_HOME"
    )
    let cache = URL(fileURLWithPath: runDirectory).appendingPathComponent("cache").path
    let state = URL(fileURLWithPath: runDirectory).appendingPathComponent("state").path
    let temporary = URL(fileURLWithPath: runDirectory).appendingPathComponent("tmp").path
    let databaseRoot: String
    if let persistentStateDirectory {
      databaseRoot = try prepareRunDirectory(persistentStateDirectory)
    } else {
      databaseRoot = runDirectory
    }
    let database = URL(fileURLWithPath: databaseRoot).appendingPathComponent("opencode.db").path
    for path in [cache, state, temporary] {
      try createPrivateDirectory(path)
    }

    var environment: [String: String] = [
      "HOME": sourceHome,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: executable,
        source: source
      ),
      "TMPDIR": temporary,
      "XDG_CONFIG_HOME": configHome,
      "XDG_CACHE_HOME": cache,
      "XDG_STATE_HOME": state,
      "XDG_DATA_HOME": dataHome,
      "OPENCODE_DB": database,
    ]
    #if os(Windows)
      environment["USERPROFILE"] = sourceHome
      environment["TEMP"] = temporary
      environment["TMP"] = temporary
    #endif
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"] {
      if let value = source[key], !value.isEmpty, !value.contains("\0") {
        environment[key] = value
      }
    }
    return environment
  }

}
