import BridgeAgentCore
import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension DirectCommandPolicy {
  public func preferredSystemBuiltInExecutable(
    project: ServiceProjectRecord,
    request: DirectCommandRequest
  ) -> String? {
    guard project.directCommandMode == .safe, request.commandID == nil else { return nil }
    guard !project.workspaceCommands.contains(where: { matchesRegistered($0, request: request) })
    else { return nil }
    return builtInResolver.systemExecutable(for: request.argv)
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
    #if os(Windows)
      guard !ruleExecutable.contains("/") && !ruleExecutable.contains("\\") else {
        return false
      }
      guard let separator = resolvedExecutable.lastIndex(where: { $0 == "/" || $0 == "\\" })
      else { return false }
      let basename = String(resolvedExecutable[resolvedExecutable.index(after: separator)...])
      guard
        basename.caseInsensitiveCompare(ruleExecutable) == .orderedSame
          || basename.caseInsensitiveCompare(ruleExecutable + ".exe") == .orderedSame
      else { return false }
      return builtInResolver.isTrustedSystemExecutable(
        resolvedExecutable,
        named: ruleExecutable
      )
    #else
      if resolvedExecutable == ruleExecutable { return true }
      guard resolvedExecutable.hasPrefix("/") else { return false }
      let url = URL(fileURLWithPath: resolvedExecutable).standardizedFileURL
      let trustedSystemDirectories: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
      return url.lastPathComponent == ruleExecutable
        && trustedSystemDirectories.contains(url.deletingLastPathComponent().path)
    #endif
  }

  private func matchesRegistered(
    _ command: ServiceWorkspaceCommand,
    request: DirectCommandRequest
  ) -> Bool {
    let executable = request.argv.first ?? ""
    let arguments = Array(request.argv.dropFirst())
    return executableMatches(command.executable, executable)
      && (command.arguments.isEmpty || arguments.starts(with: command.arguments))
  }

  private func executableMatches(_ lhs: String, _ rhs: String) -> Bool {
    #if os(Windows)
      let lhsAbsolute = AgentPathSemantics.isAbsolute(lhs, style: .windows)
      let rhsAbsolute = AgentPathSemantics.isAbsolute(rhs, style: .windows)
      guard lhsAbsolute == rhsAbsolute else { return false }
      if lhsAbsolute {
        guard let left = AgentPathSemantics.canonicalPath(lhs, style: .windows),
          let right = AgentPathSemantics.canonicalPath(rhs, style: .windows)
        else { return false }
        return left.caseInsensitiveCompare(right) == .orderedSame
      }
      return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    #else
      return lhs == rhs
    #endif
  }

  private func isBlacklisted(
    rules: [ServiceCommandBlacklistRule],
    argv: [String]
  ) -> Bool {
    let executable = argv.first ?? ""
    let executableBasename = DirectPathSemantics.basename(executable)
    #if os(Windows)
      let normalizedBasename =
        executableBasename.lowercased().hasSuffix(".exe")
        ? String(executableBasename.dropLast(4)).lowercased()
        : executableBasename.lowercased()
    #else
      let normalizedBasename = executableBasename
    #endif
    for rule in rules {
      if let ruleExecutable = rule.executable, !ruleExecutable.isEmpty {
        #if os(Windows)
          let normalizedRule = DirectPathSemantics.basename(ruleExecutable).lowercased()
          let relativeRule =
            normalizedRule.hasSuffix(".exe")
            ? String(normalizedRule.dropLast(4))
            : normalizedRule
        #else
          let relativeRule = ruleExecutable
        #endif
        let matchesExecutable: Bool
        #if os(Windows)
          matchesExecutable =
            AgentPathSemantics.isAbsolute(ruleExecutable, style: .windows)
            ? executableMatches(ruleExecutable, executable)
            : normalizedBasename == relativeRule
        #else
          matchesExecutable =
            ruleExecutable.hasPrefix("/")
            ? executable == ruleExecutable
            : normalizedBasename == relativeRule
        #endif
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
          || (executableMatches(request.argv.first ?? "", command.executable)
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
