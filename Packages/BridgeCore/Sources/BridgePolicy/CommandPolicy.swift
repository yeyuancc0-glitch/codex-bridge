import BridgeProjects
import Foundation

public struct CommandPolicy: Sendable {
  public init() {}

  package func evaluate(
    argv: [String],
    networkRequested: Bool,
    context: CommandPolicyContext
  ) -> PolicyDecision {
    guard isWellFormed(argv) else {
      return PolicyDecision(.deny, reason: .malformedRequest)
    }

    let command = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
    if isCredentialCommand(command) {
      return PolicyDecision(.deny, reason: .credentialAccess)
    }
    if isSystemWrite(command) {
      return PolicyDecision(.deny, reason: .systemWrite)
    }
    if isDestructive(argv, command: command) {
      return PolicyDecision(.deny, reason: .destructiveOperation)
    }
    if networkRequested || isNetworkCommand(command) {
      return decision(
        for: context.accessPolicy.network,
        allowed: .requireLocalApproval,
        reason: .networkAccess,
        deniedReason: .projectNetworkDenied
      )
    }
    if isPackageInstallation(argv, command: command) {
      return decision(
        for: context.accessPolicy.write,
        allowed: .requireLocalApproval,
        reason: .packageInstallation,
        deniedReason: .projectWriteDenied
      )
    }
    if isGitWrite(argv, command: command) {
      return decision(
        for: context.accessPolicy.write,
        allowed: .requireLocalApproval,
        reason: .gitWrite,
        deniedReason: .projectWriteDenied
      )
    }
    if isConfiguredVerification(argv, commands: context.verificationCommands) {
      return decision(
        for: context.accessPolicy.read,
        allowed: .allow,
        reason: .configuredVerification,
        deniedReason: .projectReadDenied
      )
    }
    if isTrustedReadOnly(argv, command: command) {
      return decision(
        for: context.accessPolicy.read,
        allowed: .allow,
        reason: .trustedReadOnly,
        deniedReason: .projectReadDenied
      )
    }
    return decision(
      for: context.accessPolicy.write,
      allowed: .requireLocalApproval,
      reason: .unsupportedCommand,
      deniedReason: .projectWriteDenied
    )
  }

  private func isWellFormed(_ argv: [String]) -> Bool {
    guard let executable = argv.first, !executable.isEmpty else { return false }
    return argv.allSatisfy { !$0.contains("\0") && !$0.contains("\n") }
  }

  private func isCredentialCommand(_ command: String) -> Bool {
    ["security", "ssh-add", "pbpaste"].contains(command)
  }

  private func isSystemWrite(_ command: String) -> Bool {
    ["sudo", "doas", "diskutil", "launchctl", "csrutil", "installer"].contains(command)
  }

  private func isDestructive(_ argv: [String], command: String) -> Bool {
    guard command == "rm" || command == "rmdir" else { return false }
    let options = Set(argv.dropFirst().filter { $0.hasPrefix("-") }.flatMap(Array.init))
    let unsafeTarget = argv.dropFirst().contains { argument in
      argument == "/" || argument == "~" || argument == ".." || argument.hasPrefix("/")
        || argument.hasPrefix("../")
    }
    return command == "rmdir" || options.contains("r") || options.contains("R")
      || options.contains("f") || unsafeTarget
  }

  private func isNetworkCommand(_ command: String) -> Bool {
    ["curl", "wget", "ssh", "scp", "sftp", "nc", "ncat"].contains(command)
  }

  private func isPackageInstallation(_ argv: [String], command: String) -> Bool {
    guard argv.count > 1 else { return false }
    let subcommand = argv[1].lowercased()
    let installers: [String: Set<String>] = [
      "npm": ["install", "i", "add", "update"],
      "pnpm": ["install", "i", "add", "update"],
      "yarn": ["install", "add", "upgrade"],
      "pip": ["install", "uninstall"],
      "pip3": ["install", "uninstall"],
      "gem": ["install", "uninstall"],
      "brew": ["install", "uninstall", "upgrade"],
    ]
    return installers[command]?.contains(subcommand) == true
  }

  private func isGitWrite(_ argv: [String], command: String) -> Bool {
    guard command == "git", argv.count > 1 else { return false }
    return !isTrustedGitRead(argv)
  }

  private func isTrustedReadOnly(_ argv: [String], command: String) -> Bool {
    guard isTrustedExecutable(argv[0], named: command) else { return false }
    if command == "pwd" { return argv.count == 1 }
    if command == "git" { return isTrustedGitRead(argv) }
    if command == "swift" { return argv.dropFirst() == ["--version"] }
    if command == "xcodebuild" { return argv.dropFirst() == ["-version"] }
    return false
  }

  private func isTrustedGitRead(_ argv: [String]) -> Bool {
    guard argv.count > 1 else { return false }
    let subcommand = argv[1].lowercased()
    let arguments = Array(argv.dropFirst(2))
    let unsafeOptions = ["--output", "--ext-diff", "--textconv", "--no-index"]
    guard
      !arguments.contains(where: { argument in
        unsafeOptions.contains(where: argument.hasPrefix) || argument.hasPrefix("/")
          || argument == ".." || argument.hasPrefix("../")
      })
    else {
      return false
    }

    switch subcommand {
    case "status", "diff", "log", "show", "rev-parse", "ls-files":
      return true
    case "branch":
      return arguments.isEmpty || arguments == ["--show-current"] || arguments == ["--list"]
    default:
      return false
    }
  }

  private func isTrustedExecutable(_ executable: String, named command: String) -> Bool {
    return executable == "/usr/bin/\(command)" || executable == "/bin/\(command)"
  }

  private func isConfiguredVerification(
    _ argv: [String],
    commands: [VerificationCommand]
  ) -> Bool {
    let wrappers: Set<String> = [
      "bash", "env", "fish", "osascript", "sh", "xargs", "zsh",
    ]
    let executable = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
    guard !wrappers.contains(executable) else { return false }
    return commands.contains { command in
      argv == [command.executable] + command.arguments
    }
  }

  private func decision(
    for permission: ProjectPermission,
    allowed: PolicyDisposition,
    reason: PolicyReason,
    deniedReason: PolicyReason
  ) -> PolicyDecision {
    switch permission {
    case .allowed:
      return PolicyDecision(allowed, reason: reason)
    case .requiresLocalApproval:
      return PolicyDecision(.requireLocalApproval, reason: reason)
    case .denied:
      return PolicyDecision(.deny, reason: deniedReason)
    default:
      return PolicyDecision(.deny, reason: deniedReason)
    }
  }
}
