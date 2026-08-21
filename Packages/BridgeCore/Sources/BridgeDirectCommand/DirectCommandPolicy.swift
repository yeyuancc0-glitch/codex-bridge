import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation

public enum DirectCommandDenialReason: Equatable, Sendable {
  case commandModeDenied
  case commandNotRegistered
  case invalidArguments
  case unknownCommand
  case networkNotAllowed
  case writeNotAllowed
  case blacklisted
}

public struct DirectCommandRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let commandID: String?
  public let argv: [String]
  /// The executable resolved by the service before policy evaluation.
  ///
  /// `argv` remains the caller's representation so registered-command matching
  /// stays source-compatible, while the policy evaluates the executable that
  /// will actually be launched.
  public let resolvedExecutable: String?
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let isValidatedSkillScript: Bool

  public init(
    projectID: ProjectID,
    commandID: String?,
    argv: [String],
    resolvedExecutable: String? = nil,
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    isValidatedSkillScript: Bool = false
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.resolvedExecutable = resolvedExecutable
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.isValidatedSkillScript = isValidatedSkillScript
  }
}

public struct DirectCommandResolution: Equatable, Sendable {
  public let allowed: Bool
  public let requiresApproval: Bool
  public let argv: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let reason: DirectCommandDenialReason?

  public init(
    allowed: Bool,
    requiresApproval: Bool,
    argv: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool,
    reason: DirectCommandDenialReason?
  ) {
    self.allowed = allowed
    self.requiresApproval = requiresApproval
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.reason = reason
  }

  public static func denied(_ reason: DirectCommandDenialReason) -> DirectCommandResolution {
    DirectCommandResolution(
      allowed: false,
      requiresApproval: false,
      argv: [],
      workingDirectory: nil,
      requiresNetwork: false,
      reason: reason
    )
  }
}

private struct SafeRule: Equatable {
  let executable: String
  let argumentsPrefix: [String]
  let requiresNetwork: Bool
}

public struct DirectCommandPolicy: Sendable {
  private let builtInSafeRules: [SafeRule]
  public let safeCommandRules: [DirectSafeCommandRule]

  public init(builtInSafeRules: [DirectSafeCommandRule] = DirectCommandPolicy.defaultSafeRules) {
    safeCommandRules = builtInSafeRules
    self.builtInSafeRules = builtInSafeRules.map {
      SafeRule(
        executable: $0.executable,
        argumentsPrefix: $0.argumentsPrefix,
        requiresNetwork: $0.requiresNetwork
      )
    }
  }

  /// codexpro-style safe prefixes: a program plus an optional exact argument prefix.
  /// `git status` allows `git status --short` but never `git push`.
  public struct DirectSafeCommandRule: Sendable, Equatable {
    public let executable: String
    public let argumentsPrefix: [String]
    public let requiresNetwork: Bool

    public init(
      executable: String,
      argumentsPrefix: [String] = [],
      requiresNetwork: Bool = false
    ) {
      self.executable = executable
      self.argumentsPrefix = argumentsPrefix
      self.requiresNetwork = requiresNetwork
    }
  }

  public static let defaultSafeRules: [DirectSafeCommandRule] = [
    DirectSafeCommandRule(executable: "pwd"),
    DirectSafeCommandRule(executable: "/bin/pwd"),
    DirectSafeCommandRule(executable: "ls"),
    DirectSafeCommandRule(executable: "/bin/ls"),
    DirectSafeCommandRule(executable: "/usr/bin/ls"),
    DirectSafeCommandRule(executable: "find", argumentsPrefix: []),
    DirectSafeCommandRule(executable: "/usr/bin/find", argumentsPrefix: []),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["status"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["status"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["diff"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["diff"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["log"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["log"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["show"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["show"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["branch"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["branch"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["rev-parse"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["rev-parse"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["ls-files"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["ls-files"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "node", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "build"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "lint"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "typecheck"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "test"]),
    DirectSafeCommandRule(executable: "grep"),
    DirectSafeCommandRule(executable: "/usr/bin/grep"),
    DirectSafeCommandRule(executable: "rg"),
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "/usr/bin/xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "xcodebuild", argumentsPrefix: ["-workspace"]),
    DirectSafeCommandRule(executable: "/usr/bin/xcodebuild", argumentsPrefix: ["-workspace"]),
    DirectSafeCommandRule(executable: "echo"),
    DirectSafeCommandRule(executable: "/bin/echo"),
    DirectSafeCommandRule(executable: "/usr/bin/echo"),
  ]

  private static let swiftPathOptions: Set<String> = [
    "--package-path", "--cache-path", "--config-path", "--security-path", "--scratch-path",
    "--swift-sdks-path", "--toolset", "--pkg-config-path", "--netrc-file", "--attachments-path",
    "--xunit-output", "--experimental-codesize-profile-output-dir", "--build-path",
    "--index-store-path", "--plugin-path", "--sbom-output-dir", "--sdk", "--toolchain",
    "--swift-sdk",
  ]

  private static let xcodebuildPathOptions: Set<String> = [
    "-project", "-workspace", "-xcconfig", "-sdk", "-resultBundlePath", "-resultStreamPath",
    "-clonedSourcePackagesDirPath", "-derivedDataPath", "-archivePath", "-exportOptionsPlist",
    "-codesizeProfileOutputDir", "-exportPath", "-importPath", "-localizationPath", "-xctestrun",
    "-testProductsPath", "-test-enumeration-output-path", "-packageCachePath",
    "-authenticationKeyPath", "-importPlatform",
  ]

  private static let xcodebuildResponseFileOptions: Set<String> = [
    "-only-testing", "-skip-testing",
  ]

  private static let xcodebuildResponseFilePrefixes: [String] = [
    "-only-testing:", "-skip-testing:", "-only-testing=", "-skip-testing=",
  ]

  private static let swiftDeniedOptions: Set<String> = [
    "--disable-sandbox"
  ]

  private static let xcodebuildDeniedOptions: Set<String> = [
    "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
  ]

  private func isProjectLocalExecutable(_ executable: String, projectRoot: String) -> Bool {
    guard executable.contains("/") else { return false }
    guard
      let resolved = projectContainedPath(
        executable,
        projectRoot: projectRoot,
        workingDirectory: nil
      )
    else { return false }
    let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    return resolved != root || FileManager.default.isExecutableFile(atPath: resolved)
  }

  private func projectContainedPath(
    _ value: String,
    projectRoot: String,
    workingDirectory: String?
  ) -> String? {
    guard !value.isEmpty, !value.hasPrefix("~"), !value.lowercased().hasPrefix("file:") else {
      return nil
    }
    let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let base: String
    if let workingDirectory, !workingDirectory.isEmpty {
      if workingDirectory == "." || workingDirectory == "./" {
        base = root
      } else {
        let secure = try? SecureRelativePath(workingDirectory)
        guard let secure else { return nil }
        base =
          URL(fileURLWithPath: root, isDirectory: true)
          .appendingPathComponent(secure.value, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path
      }
    } else {
      base = root
    }
    let candidate: URL
    if value.hasPrefix("/") {
      candidate = URL(fileURLWithPath: value)
    } else {
      guard
        !value.split(separator: "/", omittingEmptySubsequences: false)
          .contains(where: { $0 == ".." || $0.isEmpty })
      else { return nil }
      candidate = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(value)
    }
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
    return resolved
  }

  private func safePathArgument(
    _ value: String,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    value == "-"
      || projectContainedPath(
        value,
        projectRoot: projectRoot,
        workingDirectory: workingDirectory
      ) != nil
  }

  private func listArgumentsAreSafe(
    _ arguments: ArraySlice<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var pathsEnabled = false
    for argument in arguments {
      if pathsEnabled {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
      } else if argument == "--" {
        pathsEnabled = true
      } else if argument.hasPrefix("-") && argument != "-" {
        continue
      } else {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
      }
    }
    return true
  }

  private func findArgumentsAreSafe(
    _ arguments: ArraySlice<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    let denied = Set([
      "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprint0",
      "-fprintf", "-L", "-H", "-follow",
    ])
    let valuePredicates = Set([
      "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex",
      "-iregex", "-type", "-size", "-mtime", "-atime", "-ctime", "-mmin", "-amin",
      "-cmin", "-user", "-group", "-perm", "-maxdepth", "-mindepth", "-fstype",
      "-inum", "-links", "-used", "-uid", "-gid",
    ])
    let predicates = Set([
      "!", "-not", "-a", "-and", "-o", "-or", "(", ")", "-print", "-print0", "-ls",
      "-xdev", "-mount", "-depth", "-d", "-prune", "-daystart", "-ignore_readdir_race",
      "-noignore_readdir_race", "-true", "-false", "-empty", "-readable", "-writable",
      "-executable",
    ])
    var expressionStarted = false
    var expectsValue = false
    var pathsEnabled = false
    for argument in arguments {
      if expectsValue {
        expectsValue = false
        continue
      }
      if pathsEnabled {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        continue
      }
      if argument == "--" {
        pathsEnabled = true
        continue
      }
      if !expressionStarted && !argument.hasPrefix("-") && argument != "!" && argument != "(" {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        continue
      }
      expressionStarted = true
      guard !denied.contains(argument) else { return false }
      if valuePredicates.contains(argument) {
        expectsValue = true
      } else if !predicates.contains(argument) {
        return false
      }
    }
    return !expectsValue
  }

  private func safeBuiltInInvocation(
    _ argv: [String],
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    guard let executable = argv.first else { return false }
    let basename = executable.split(separator: "/").last.map(String.init) ?? executable
    switch basename {
    case "pwd":
      return argv.dropFirst().allSatisfy { ["-L", "-P"].contains($0) }
    case "ls":
      return listArgumentsAreSafe(
        argv.dropFirst(), projectRoot: projectRoot, workingDirectory: workingDirectory)
    case "find":
      return findArgumentsAreSafe(
        argv.dropFirst(), projectRoot: projectRoot, workingDirectory: workingDirectory)
    case "grep", "rg":
      return DirectSearchArgumentValidator.areArgumentsSafe(
        executable: basename,
        argv.dropFirst(),
        pathIsSafe: {
          safePathArgument(
            $0,
            projectRoot: projectRoot,
            workingDirectory: workingDirectory
          )
        }
      )
    case "git":
      let denied = [
        "--git-dir", "--work-tree", "--no-index", "--output", "--ext-diff", "--textconv",
        "--exec-path", "--config-env", "-C", "-c", "-p", "--paginate",
      ]
      return !argv.dropFirst().contains { argument in
        denied.contains(argument)
          || denied.dropLast().contains(where: { argument.hasPrefix($0 + "=") })
      }
    case "npm":
      let denied = [
        "--prefix", "--userconfig", "--globalconfig", "--cache", "--logs-dir", "--cafile",
        "--cert", "--key", "--script-shell", "--nodedir", "--tmp", "--workspace", "-w",
      ]
      return !argv.dropFirst().contains { argument in
        denied.contains(argument) || denied.contains { argument.hasPrefix($0 + "=") }
      }
    case "swift":
      return !containsOption(argv.dropFirst(), options: Self.swiftDeniedOptions)
        && pathOptionsAreContained(
          argv.dropFirst(), options: Self.swiftPathOptions, projectRoot: projectRoot,
          workingDirectory: workingDirectory
        )
    case "xcodebuild":
      return !containsOption(argv.dropFirst(), options: Self.xcodebuildDeniedOptions)
        && pathOptionsAreContained(
          argv.dropFirst(), options: Self.xcodebuildPathOptions, projectRoot: projectRoot,
          workingDirectory: workingDirectory
        )
        && responseFileOptionsAreContained(
          argv.dropFirst(), options: Self.xcodebuildResponseFileOptions,
          prefixes: Self.xcodebuildResponseFilePrefixes,
          projectRoot: projectRoot, workingDirectory: workingDirectory
        )
    default:
      return true
    }
  }

  private func containsOption(_ arguments: ArraySlice<String>, options: Set<String>) -> Bool {
    arguments.contains { argument in
      options.contains(argument)
        || options.contains { argument.hasPrefix($0 + "=") }
    }
  }

  private func pathOptionsAreContained(
    _ arguments: ArraySlice<String>,
    options: Set<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var expectsPath = false
    for argument in arguments {
      if expectsPath {
        guard !argument.hasPrefix("-") || argument == "-" else { return false }
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        expectsPath = false
      } else if let option = options.first(where: { argument == $0 || argument.hasPrefix($0 + "=") }
      ) {
        if argument == option {
          expectsPath = true
        } else {
          let value = String(argument.dropFirst(option.count + 1))
          guard
            safePathArgument(value, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
      }
    }
    return !expectsPath
  }

  private func responseFileOptionsAreContained(
    _ arguments: ArraySlice<String>,
    options: Set<String>,
    prefixes: [String],
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var expectsValue = false
    for argument in arguments {
      if expectsValue {
        if argument.hasPrefix("@") {
          let path = String(argument.dropFirst())
          guard
            safePathArgument(path, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
        expectsValue = false
      } else if options.contains(argument) {
        expectsValue = true
      } else if let prefix = prefixes.first(where: { argument.hasPrefix($0) }) {
        let value = String(argument.dropFirst(prefix.count))
        if value.hasPrefix("@") {
          let path = String(value.dropFirst())
          guard
            safePathArgument(path, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
      }
    }
    return !expectsValue
  }

  private func matchesSafeRule(_ rule: SafeRule, argv: [String]) -> Bool {
    guard let executable = argv.first,
      safeRuleExecutableMatches(rule.executable, resolvedExecutable: executable)
    else { return false }
    guard !rule.argumentsPrefix.isEmpty else { return true }
    let arguments = Array(argv.dropFirst())
    guard arguments.count >= rule.argumentsPrefix.count else { return false }
    return Array(arguments.prefix(rule.argumentsPrefix.count)) == rule.argumentsPrefix
  }

  private func safeRuleExecutableMatches(
    _ ruleExecutable: String,
    resolvedExecutable: String
  ) -> Bool {
    if resolvedExecutable == ruleExecutable { return true }
    guard resolvedExecutable.hasPrefix("/") else { return false }
    let url = URL(fileURLWithPath: resolvedExecutable).standardizedFileURL
    let trustedSystemDirectories: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    return url.lastPathComponent == ruleExecutable
      && trustedSystemDirectories.contains(url.deletingLastPathComponent().path)
  }

  private func matchesRegistered(
    _ command: ServiceWorkspaceCommand,
    request: DirectCommandRequest
  ) -> Bool {
    let executable = request.argv.first ?? ""
    let arguments = Array(request.argv.dropFirst())
    return command.executable == executable
      && (command.arguments.isEmpty || arguments.starts(with: command.arguments))
  }

  private func isBlacklisted(
    rules: [ServiceCommandBlacklistRule],
    argv: [String]
  ) -> Bool {
    let executable = argv.first ?? ""
    let executableBasename = executable.split(separator: "/").last.map(String.init) ?? ""
    for rule in rules {
      if let ruleExecutable = rule.executable, !ruleExecutable.isEmpty {
        let matchesExecutable =
          ruleExecutable.hasPrefix("/")
          ? executable == ruleExecutable
          : executableBasename == ruleExecutable
        if matchesExecutable {
          return true
        }
      }
      if let pattern = rule.pattern, !pattern.isEmpty {
        if argv.contains(where: { $0.localizedCaseInsensitiveContains(pattern) }) {
          return true
        }
      }
    }
    return false
  }

  public func resolve(
    project: ServiceProjectRecord,
    request: DirectCommandRequest
  ) -> DirectCommandResolution {
    guard project.directCommandMode != .denied else {
      return .denied(.commandModeDenied)
    }
    let requestedExecutable = request.argv.first ?? ""
    let executable = request.resolvedExecutable ?? requestedExecutable
    if request.commandID == nil {
      guard !executable.isEmpty else { return .denied(.invalidArguments) }
    }
    guard request.argv.count <= 128, request.workingDirectory?.utf8.count ?? 0 <= 1_024 else {
      return .denied(.invalidArguments)
    }

    let matched: ServiceWorkspaceCommand?
    if let commandID = request.commandID {
      guard let command = project.workspaceCommands.first(where: { $0.id == commandID }) else {
        return .denied(.unknownCommand)
      }
      let arguments = Array(request.argv.dropFirst())
      guard
        request.argv.isEmpty
          || (request.argv.first == command.executable
            && (command.arguments.isEmpty || arguments.starts(with: command.arguments)))
      else {
        return .denied(.invalidArguments)
      }
      matched = command
    } else {
      matched = project.workspaceCommands.first { matchesRegistered($0, request: request) }
    }

    let effectiveArgv: [String]
    if let matched {
      effectiveArgv =
        request.argv.isEmpty
        ? [matched.executable] + matched.arguments
        : request.argv
    } else {
      effectiveArgv = request.argv
    }

    let policyArgv: [String]
    if let resolvedExecutable = request.resolvedExecutable, !effectiveArgv.isEmpty {
      policyArgv = [resolvedExecutable] + effectiveArgv.dropFirst()
    } else {
      policyArgv = effectiveArgv
    }

    if isBlacklisted(rules: project.commandBlacklist, argv: policyArgv) {
      return .denied(.blacklisted)
    }

    let matchedBuiltInRule = builtInSafeRules.first { matchesSafeRule($0, argv: policyArgv) }
    switch project.directCommandMode {
    case .denied:
      return .denied(.commandModeDenied)
    case .safe:
      let allowed =
        matched != nil
        || matchedBuiltInRule != nil
        || isProjectLocalExecutable(
          executable, projectRoot: project.root.canonicalPath)
        || request.isValidatedSkillScript
      guard allowed else { return .denied(.commandNotRegistered) }
      if matchedBuiltInRule != nil,
        !safeBuiltInInvocation(
          policyArgv,
          projectRoot: project.root.canonicalPath,
          workingDirectory: matched?.workingDirectory ?? request.workingDirectory
        )
      {
        return .denied(.invalidArguments)
      }
    case .full:
      break
    }

    let needsNetwork =
      matched?.requiresNetwork == true || matchedBuiltInRule?.requiresNetwork == true
      || request.requiresNetwork
    if needsNetwork {
      guard project.accessPolicy.network != .denied else { return .denied(.networkNotAllowed) }
    }
    guard project.accessPolicy.write != .denied else { return .denied(.writeNotAllowed) }

    let risk = matched?.risk ?? .normal
    let requiresApproval =
      risk == .elevated
      || project.accessPolicy.write == .requiresLocalApproval
      || (needsNetwork && project.accessPolicy.network == .requiresLocalApproval)
    return DirectCommandResolution(
      allowed: true,
      requiresApproval: requiresApproval,
      argv: policyArgv,
      workingDirectory: matched?.workingDirectory ?? request.workingDirectory,
      requiresNetwork: needsNetwork,
      reason: nil
    )
  }
}
