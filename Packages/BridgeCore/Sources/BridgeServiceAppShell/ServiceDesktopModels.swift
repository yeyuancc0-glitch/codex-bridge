import BridgeIPC
import BridgeMCP
import CryptoKit
import Foundation

extension MCPServiceTaskSnapshot {
  var isTerminal: Bool {
    ["completed", "failed", "interrupted"].contains(status)
  }

  var isRunning: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(status)
  }
}

extension BridgeServiceRegistrationStatus {
  var localizedTitle: String {
    switch self {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}

public struct BridgeProjectPolicyDraft: Equatable, Sendable {
  public var readPermission: String
  public var writePermission: String
  public var networkPermission: String

  public init(project: MCPProjectSummary) {
    readPermission = project.capabilities.read
    writePermission = project.capabilities.write
    networkPermission = project.capabilities.network
  }
}

public struct BridgeWorkspaceCommandDraft: Equatable, Identifiable, Sendable {
  public var name: String
  public var executable: String
  public var arguments: String
  public var workingDirectory: String
  public var requiresNetwork: Bool
  public var risk: String

  public var id: String {
    BridgeWorkspaceCommandDraft.stableID(
      name: name,
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory
    )
  }

  public init(
    name: String = "",
    executable: String = "",
    arguments: String = "",
    workingDirectory: String = "",
    requiresNetwork: Bool = false,
    risk: String = "normal"
  ) {
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }

  public init(command: MCPProjectCommand) {
    name = command.name
    executable = command.executable
    arguments = command.arguments.joined(separator: "\n")
    workingDirectory = command.workingDirectory ?? ""
    requiresNetwork = command.requiresNetwork
    risk = command.risk
  }

  public static func stableID(
    name: String,
    executable: String,
    arguments: String,
    workingDirectory: String
  ) -> String {
    let canonical = [
      name.trimmingCharacters(in: .whitespacesAndNewlines),
      executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments.split(separator: "\n").joined(separator: "\u{0}"),
      workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
    ].joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "wcmd_" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
  }

  public func toIPCCommand() -> IPCWorkspaceCommand {
    IPCWorkspaceCommand(
      commandID: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments: arguments.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
      workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty ? nil : workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
      requiresNetwork: requiresNetwork,
      risk: risk
    )
  }
}

public struct BridgeBlacklistDraft: Equatable, Identifiable, Sendable {
  public var executable: String
  public var pattern: String

  public var id: String {
    BridgeBlacklistDraft.stableID(executable: executable, pattern: pattern)
  }

  public init(executable: String = "", pattern: String = "") {
    self.executable = executable
    self.pattern = pattern
  }

  public init(rule: MCPCommandBlacklistRule) {
    executable = rule.executable ?? ""
    pattern = rule.pattern ?? ""
  }

  public static func stableID(executable: String, pattern: String) -> String {
    let canonical = [
      executable.trimmingCharacters(in: .whitespacesAndNewlines),
      pattern.trimmingCharacters(in: .whitespacesAndNewlines),
    ].joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "blk_" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
  }

  public func toIPCRule() -> IPCBlacklistRule {
    let executableValue = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    let patternValue = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    return IPCBlacklistRule(
      ruleID: id,
      executable: executableValue.isEmpty ? nil : executableValue,
      pattern: patternValue.isEmpty ? nil : patternValue
    )
  }
}
