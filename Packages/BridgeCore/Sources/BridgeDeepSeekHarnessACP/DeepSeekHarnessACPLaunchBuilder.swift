import BridgeACP
import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DeepSeekHarnessACPLaunchBuilder: Sendable {
  public let profile: DeepSeekHarnessACPProfile
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration

  public init(
    profile: DeepSeekHarnessACPProfile,
    maximumFrameBytes: Int = DeepSeekHarnessACPConstants.maximumFrameBytes,
    maximumStandardErrorBytes: Int = DeepSeekHarnessACPConstants.maximumStandardErrorBytes,
    maximumLifetime: Duration = DeepSeekHarnessACPConstants.maximumProcessLifetime
  ) {
    self.profile = profile
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
  }

  public init(
    configurationTemplate: Data? = nil,
    maximumFrameBytes: Int = DeepSeekHarnessACPConstants.maximumFrameBytes,
    maximumStandardErrorBytes: Int = DeepSeekHarnessACPConstants.maximumStandardErrorBytes,
    maximumLifetime: Duration = DeepSeekHarnessACPConstants.maximumProcessLifetime
  ) throws {
    try self.init(
      profile: DeepSeekHarnessACPProfile(configurationTemplate: configurationTemplate),
      maximumFrameBytes: maximumFrameBytes,
      maximumStandardErrorBytes: maximumStandardErrorBytes,
      maximumLifetime: maximumLifetime
    )
  }

  public func make(
    installation: AgentInstallation,
    projectRoot: String,
    runDirectory: String,
    networkAllowed: Bool,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> DeepSeekHarnessACPLaunchConfiguration {
    guard !networkAllowed else {
      throw AgentRuntimeError.invalidRequest("request.networkAccessRequested")
    }
    let validated = try profile.validate(installation)
    let project = try canonicalExistingDirectory(projectRoot, field: "projectRoot")
    let runtime = try preparePrivateDirectory(runDirectory, field: "runDirectory")
    let environment = try makeEnvironment(
      nodeInterpreter: validated.nodeInterpreterPath,
      projectRoot: project,
      runDirectory: runtime,
      sourceEnvironment: sourceEnvironment
    )
    let runtimeConfiguration = try prepareRuntimeProfile(
      sourceRoot: validated.sourceRoot,
      runDirectory: runtime
    )
    let configurationDirectory = URL(fileURLWithPath: validated.configurationPath)
      .deletingLastPathComponent().standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: configurationDirectory) else {
      throw AgentRuntimeError.processUnavailable
    }
    let argv = [
      validated.nodeInterpreterPath,
      validated.executablePath,
      "--config",
      runtimeConfiguration,
    ]
    return DeepSeekHarnessACPLaunchConfiguration(
      process: ACPProcessTransportConfiguration(
        argv: argv,
        workingDirectory: configurationDirectory,
        environment: environment,
        maximumFrameBytes: maximumFrameBytes,
        maximumStandardErrorBytes: maximumStandardErrorBytes,
        maximumLifetime: maximumLifetime,
        inputEOFGracePeriod: .seconds(6)
      ),
      runDirectory: runtime,
      resolvedNodeInterpreterPath: validated.nodeInterpreterPath,
      resolvedExecutablePath: validated.executablePath,
      resolvedConfigurationPath: validated.configurationPath
    )
  }

  func prepareRuntimeProfile(sourceRoot: String, runDirectory: String) throws -> String {
    let moduleDirectory = URL(fileURLWithPath: sourceRoot, isDirectory: true)
      .appendingPathComponent("node_modules/.pnpm/node_modules", isDirectory: true)
      .standardizedFileURL.path
    let resolvedModuleDirectory = URL(fileURLWithPath: moduleDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard resolvedModuleDirectory == moduleDirectory,
      FileManager.default.fileExists(atPath: moduleDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_modules")
    }

    let runtimeProfile = URL(fileURLWithPath: runDirectory, isDirectory: true)
      .appendingPathComponent("profile", isDirectory: true).path
    try createPrivateDirectory(runtimeProfile)
    let configuration = URL(fileURLWithPath: runtimeProfile, isDirectory: true)
      .appendingPathComponent("cordis.yml").path
    do {
      try profile.configurationTemplate.write(
        to: URL(fileURLWithPath: configuration),
        options: .atomic
      )
      guard chmod(configuration, 0o600) == 0 else {
        throw AgentRuntimeError.processUnavailable
      }
      try FileManager.default.createSymbolicLink(
        atPath: URL(fileURLWithPath: runtimeProfile, isDirectory: true)
          .appendingPathComponent("node_modules").path,
        withDestinationPath: moduleDirectory
      )
      return configuration
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  public static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  private func makeEnvironment(
    nodeInterpreter: String,
    projectRoot: String,
    runDirectory: String,
    sourceEnvironment: [String: String]
  ) throws -> [String: String] {
    let home = URL(fileURLWithPath: runDirectory).appendingPathComponent("home").path
    let xdgConfig = URL(fileURLWithPath: runDirectory).appendingPathComponent("xdg-config").path
    let xdgCache = URL(fileURLWithPath: runDirectory).appendingPathComponent("xdg-cache").path
    let xdgData = URL(fileURLWithPath: runDirectory).appendingPathComponent("xdg-data").path
    let xdgState = URL(fileURLWithPath: runDirectory).appendingPathComponent("xdg-state").path
    let temporary = URL(fileURLWithPath: runDirectory).appendingPathComponent("tmp").path
    let dshHome = URL(fileURLWithPath: runDirectory).appendingPathComponent("dsh-home").path
    let snapshots = URL(fileURLWithPath: runDirectory).appendingPathComponent("snapshots").path
    for path in [home, xdgConfig, xdgCache, xdgData, xdgState, temporary, dshHome, snapshots] {
      try createPrivateDirectory(path)
    }

    var environment: [String: String] = [
      "HOME": home,
      "PATH": Self.trustedPath(nodeInterpreter: nodeInterpreter),
      "TMPDIR": temporary,
      "XDG_CONFIG_HOME": xdgConfig,
      "XDG_CACHE_HOME": xdgCache,
      "XDG_DATA_HOME": xdgData,
      "XDG_STATE_HOME": xdgState,
      "DSH_HOME": dshHome,
      "DSH_SNAPSHOT_SESSIONS_ROOT": snapshots,
      "DSH_WORKSPACE_ROOT": projectRoot,
      "DSH_PERMISSION_MODE": "read-only",
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"] {
      if let value = sourceEnvironment[key],
        !value.isEmpty,
        !value.contains("\0"),
        value.rangeOfCharacter(from: .controlCharacters) == nil
      {
        environment[key] = value
      }
    }
    return environment
  }

  private static func trustedPath(nodeInterpreter: String) -> String {
    let candidates = [
      URL(fileURLWithPath: nodeInterpreter).deletingLastPathComponent().path,
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

  private func canonicalExistingDirectory(_ value: String, field: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    let canonical = URL(fileURLWithPath: value, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return canonical
  }

  private func preparePrivateDirectory(_ value: String, field: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    let canonical = URL(fileURLWithPath: value, isDirectory: true)
      .standardizedFileURL.path
    do {
      try createPrivateDirectory(canonical)
      return URL(fileURLWithPath: canonical, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private func createPrivateDirectory(_ path: String) throws {
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
}
