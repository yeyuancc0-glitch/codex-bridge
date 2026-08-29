import BridgeDomain
import BridgeIPC
import BridgeProjects
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  static func projectPolicy(
    read: String,
    write: String,
    network: String
  ) throws -> ProjectAccessPolicy {
    guard read != ProjectPermission.requiresLocalApproval.rawValue else {
      throw ServiceStoreError.invalidArgument("project.policy.read")
    }
    let values = [read, write, network]
    let allowed = Set([
      ProjectPermission.denied.rawValue,
      ProjectPermission.requiresLocalApproval.rawValue,
      ProjectPermission.allowed.rawValue,
    ])
    guard values.allSatisfy(allowed.contains) else {
      throw ServiceStoreError.invalidArgument("project.policy")
    }
    return ProjectAccessPolicy(
      read: ProjectPermission(rawValue: read),
      write: ProjectPermission(rawValue: write),
      network: ProjectPermission(rawValue: network)
    )
  }

  static func workspaceCommands(
    _ commands: [IPCWorkspaceCommand]
  ) throws -> [ServiceWorkspaceCommand] {
    guard commands.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    return try commands.map { command in
      guard let risk = ServiceWorkspaceCommandRisk(rawValue: command.risk) else {
        throw ServiceStoreError.invalidArgument("workspaceCommand.risk")
      }
      return try ServiceWorkspaceCommand(
        id: command.commandID,
        name: command.name,
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: command.workingDirectory,
        requiresNetwork: command.requiresNetwork,
        risk: risk
      )
    }
  }

  static func blacklistRules(
    _ rules: [IPCBlacklistRule]
  ) throws -> [ServiceCommandBlacklistRule] {
    guard rules.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    return try rules.map { rule in
      try ServiceCommandBlacklistRule(
        id: rule.ruleID,
        executable: rule.executable,
        pattern: rule.pattern
      )
    }
  }

  static func absoluteDirectoryURL(_ path: String) throws -> URL {
    guard !path.isEmpty,
      path.hasPrefix("/"),
      path.utf8.count <= 16_384,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("project.path")
    }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }
}
