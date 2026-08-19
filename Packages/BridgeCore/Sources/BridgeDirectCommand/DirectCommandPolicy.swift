import BridgeDomain
import BridgeProjects
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
  public let workingDirectory: String?
  public let requiresNetwork: Bool

  public init(
    projectID: ProjectID,
    commandID: String?,
    argv: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
  }
}

public struct DirectCommandResolution: Equatable, Sendable {
  public let allowed: Bool
  public let requiresApproval: Bool
  public let argv: [String]
  public let requiresNetwork: Bool
  public let reason: DirectCommandDenialReason?

  public init(
    allowed: Bool,
    requiresApproval: Bool,
    argv: [String],
    requiresNetwork: Bool,
    reason: DirectCommandDenialReason?
  ) {
    self.allowed = allowed
    self.requiresApproval = requiresApproval
    self.argv = argv
    self.requiresNetwork = requiresNetwork
    self.reason = reason
  }

  public static func denied(_ reason: DirectCommandDenialReason) -> DirectCommandResolution {
    DirectCommandResolution(
      allowed: false,
      requiresApproval: false,
      argv: [],
      requiresNetwork: false,
      reason: reason
    )
  }
}

private struct SafeRule: Equatable {
  let executable: String
  let argumentsPrefix: [String]
}

public struct DirectCommandPolicy: Sendable {
  private let builtInSafeRules: [SafeRule]

  public init(builtInSafeRules: [DirectSafeCommandRule] = DirectCommandPolicy.defaultSafeRules) {
    self.builtInSafeRules = builtInSafeRules.map {
      SafeRule(executable: $0.executable, argumentsPrefix: $0.argumentsPrefix)
    }
  }

  /// codexpro-style safe prefixes: a program plus an optional exact argument prefix.
  /// `git status` allows `git status --short` but never `git push`.
  public struct DirectSafeCommandRule: Sendable, Equatable {
    public let executable: String
    public let argumentsPrefix: [String]

    public init(executable: String, argumentsPrefix: [String] = []) {
      self.executable = executable
      self.argumentsPrefix = argumentsPrefix
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
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "/usr/bin/xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "echo"),
    DirectSafeCommandRule(executable: "/bin/echo"),
    DirectSafeCommandRule(executable: "/usr/bin/echo"),
  ]

  private func matchesSafeRule(_ rule: SafeRule, argv: [String]) -> Bool {
    guard let executable = argv.first, executable == rule.executable else { return false }
    guard !rule.argumentsPrefix.isEmpty else { return true }
    let arguments = Array(argv.dropFirst())
    guard arguments.count >= rule.argumentsPrefix.count else { return false }
    return Array(arguments.prefix(rule.argumentsPrefix.count)) == rule.argumentsPrefix
  }

  private func matchesRegistered(
    _ command: ServiceWorkspaceCommand,
    request: DirectCommandRequest
  ) -> Bool {
    let executable = request.argv.first ?? ""
    return command.executable == executable
      && command.arguments == Array(request.argv.dropFirst())
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
    let executable = request.argv.first ?? ""
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
      guard request.argv.isEmpty || request.argv == [command.executable] + command.arguments else {
        return .denied(.invalidArguments)
      }
      matched = command
    } else {
      matched = project.workspaceCommands.first { matchesRegistered($0, request: request) }
    }

    let effectiveArgv: [String]
    if let matched {
      effectiveArgv = [matched.executable] + matched.arguments
    } else {
      effectiveArgv = request.argv
    }

    if isBlacklisted(rules: project.commandBlacklist, argv: effectiveArgv) {
      return .denied(.blacklisted)
    }

    switch project.directCommandMode {
    case .denied:
      return .denied(.commandModeDenied)
    case .safe:
      let allowed =
        matched != nil
        || builtInSafeRules.contains { matchesSafeRule($0, argv: request.argv) }
        || project.safeWhitelist.contains { rule in
          matchesSafeRule(
            SafeRule(executable: rule.executable, argumentsPrefix: rule.argumentsPrefix),
            argv: request.argv
          )
        }
      guard allowed else { return .denied(.commandNotRegistered) }
    case .full:
      break
    }

    let needsNetwork = matched?.requiresNetwork == true || request.requiresNetwork
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
      argv: effectiveArgv,
      requiresNetwork: needsNetwork,
      reason: nil
    )
  }
}
