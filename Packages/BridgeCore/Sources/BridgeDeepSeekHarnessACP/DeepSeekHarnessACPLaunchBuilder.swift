import BridgeACP
import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
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
    modelID: String? = nil,
    reasoningEffort: String? = nil,
    mutationIntent: AgentMutationIntent = .readOnly,
    networkAllowed _: Bool,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> DeepSeekHarnessACPLaunchConfiguration {
    let validated = try profile.validate(installation)
    let project = try DeepSeekHarnessACPPathSupport.canonicalExistingDirectory(
      projectRoot,
      field: "projectRoot"
    )
    let runtime = try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      runDirectory,
      field: "runDirectory"
    )
    let environment = try makeEnvironment(
      nodeInterpreter: validated.nodeInterpreterPath,
      projectRoot: project,
      runDirectory: runtime,
      mutationIntent: mutationIntent,
      sourceEnvironment: sourceEnvironment
    )
    let runtimeConfiguration = try prepareRuntimeProfile(
      sourceRoot: validated.sourceRoot,
      runDirectory: runtime,
      configurationData: validated.configurationData,
      modelID: modelID,
      reasoningEffort: reasoningEffort,
      mutationIntent: mutationIntent
    )
    guard
      let configurationDirectory = DeepSeekHarnessACPPathSupport.existingParentDirectory(
        of: validated.configurationPath
      )
    else {
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

  func prepareRuntimeProfile(
    sourceRoot: String,
    runDirectory: String,
    configurationData: Data? = nil,
    modelID: String? = nil,
    reasoningEffort: String? = nil,
    mutationIntent: AgentMutationIntent = .readOnly
  ) throws -> String {
    let moduleDirectory = try DeepSeekHarnessACPPathSupport.append(
      ["node_modules", ".pnpm", "node_modules"],
      to: sourceRoot,
      isDirectory: true
    )
    let resolvedModuleDirectory = URL(fileURLWithPath: moduleDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard DeepSeekHarnessACPPathSupport.samePath(resolvedModuleDirectory, moduleDirectory),
      FileManager.default.fileExists(atPath: moduleDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_modules")
    }

    let runtimeProfile = try DeepSeekHarnessACPPathSupport.append(
      "profile",
      to: runDirectory,
      isDirectory: true
    )
    try DeepSeekHarnessACPPathSupport.createPrivateDirectory(runtimeProfile)
    let configuration = try DeepSeekHarnessACPPathSupport.append("cordis.yml", to: runtimeProfile)
    do {
      let stagedConfiguration = try DeepSeekHarnessACPModelCatalog.runtimeConfiguration(
        from: configurationData ?? profile.configurationTemplate,
        template: profile.configurationTemplate,
        modelID: modelID,
        reasoningEffort: reasoningEffort
      )
      let runtimeConfiguration = try Self.replaceSandboxMode(
        in: stagedConfiguration,
        mutationIntent: mutationIntent
      )
      try runtimeConfiguration.write(
        to: URL(fileURLWithPath: configuration),
        options: .atomic
      )
      #if !os(Windows)
        guard chmod(configuration, 0o600) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      try FileManager.default.createSymbolicLink(
        atPath: try DeepSeekHarnessACPPathSupport.append("node_modules", to: runtimeProfile),
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
    guard !path.isEmpty, AgentPathSemantics.isAbsolute(path),
      let canonical = AgentPathSemantics.canonicalPath(path),
      AgentPathSemantics.directoryPath(of: canonical) != nil
    else { return }
    try? FileManager.default.removeItem(atPath: canonical)
  }

  private func makeEnvironment(
    nodeInterpreter: String,
    projectRoot: String,
    runDirectory: String,
    mutationIntent: AgentMutationIntent,
    sourceEnvironment: [String: String]
  ) throws -> [String: String] {
    let home = try AgentProviderEnvironment.homeDirectory(source: sourceEnvironment)
    let xdgConfig = try DeepSeekHarnessACPPathSupport.append("xdg-config", to: runDirectory)
    let xdgCache = try DeepSeekHarnessACPPathSupport.append("xdg-cache", to: runDirectory)
    let xdgData = try DeepSeekHarnessACPPathSupport.append("xdg-data", to: runDirectory)
    let xdgState = try DeepSeekHarnessACPPathSupport.append("xdg-state", to: runDirectory)
    let temporary = try DeepSeekHarnessACPPathSupport.append("tmp", to: runDirectory)
    let dshHome = try DeepSeekHarnessACPPathSupport.append("dsh-home", to: runDirectory)
    let snapshots = try DeepSeekHarnessACPPathSupport.append("snapshots", to: runDirectory)
    for path in [xdgConfig, xdgCache, xdgData, xdgState, temporary, dshHome, snapshots] {
      try DeepSeekHarnessACPPathSupport.createPrivateDirectory(path)
    }

    var environment: [String: String] = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: nodeInterpreter,
        source: sourceEnvironment
      ),
      "TMPDIR": temporary,
      "XDG_CONFIG_HOME": xdgConfig,
      "XDG_CACHE_HOME": xdgCache,
      "XDG_DATA_HOME": xdgData,
      "XDG_STATE_HOME": xdgState,
      "DSH_HOME": dshHome,
      "DSH_SNAPSHOT_SESSIONS_ROOT": snapshots,
      "DSH_WORKSPACE_ROOT": projectRoot,
      "DSH_PERMISSION_MODE": Self.permissionMode(for: mutationIntent),
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
    #if os(Windows)
      environment["USERPROFILE"] = home
      environment["TEMP"] = temporary
      environment["TMP"] = temporary
      for key in [
        "SystemRoot", "SystemDrive", "ComSpec", "PATHEXT", "LOCALAPPDATA", "APPDATA",
      ] {
        if let value = sourceEnvironment.first(where: {
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
    return environment
  }

  private static func permissionMode(for mutationIntent: AgentMutationIntent) -> String {
    switch mutationIntent {
    case .readOnly:
      "read-only"
    case .workspaceWrite:
      "workspace-write"
    }
  }

  private static func replaceSandboxMode(
    in configuration: Data,
    mutationIntent: AgentMutationIntent
  ) throws -> Data {
    guard var value = String(data: configuration, encoding: .utf8) else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let prefix = "    mode: "
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    let matching = lines.indices.filter { lines[$0].hasPrefix(prefix) }
    guard matching.count == 1,
      lines[matching[0]] == prefix + "read-only"
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let mode = permissionMode(for: mutationIntent)
    guard mode != "danger-full-access" else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    var updated = lines.map(String.init)
    updated[matching[0]] = prefix + mode
    value = updated.joined(separator: "\n")
    return Data(value.utf8)
  }

}
