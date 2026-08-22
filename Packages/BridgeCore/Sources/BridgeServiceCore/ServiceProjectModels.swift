import BridgeDomain
import BridgeProjects
import Crypto
import Foundation

public enum ServiceDirectCommandMode: String, Codable, CaseIterable, Sendable {
  case denied
  case safe
  case full

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    // Pre-schema-v6 configurations used "registered"; it now behaves as safe mode.
    self = raw == "registered" ? .safe : Self(rawValue: raw) ?? .denied
  }
}

public enum ServiceWorkspaceCommandRisk: String, Codable, CaseIterable, Sendable {
  case normal
  case elevated
}

public struct ServiceCommandBlacklistRule: Codable, Equatable, Sendable {
  public let id: String
  public let executable: String?
  public let pattern: String?

  public init(
    id: String,
    executable: String? = nil,
    pattern: String? = nil
  ) throws {
    try ServiceValidation.identifier(id, field: "blacklistRule.id", maximumBytes: 128)
    if let executable {
      try ServiceValidation.text(executable, field: "blacklistRule.executable", maximumBytes: 4_096)
    }
    if let pattern {
      try ServiceValidation.text(pattern, field: "blacklistRule.pattern", maximumBytes: 4_096)
    }
    guard executable != nil || pattern != nil else {
      throw ServiceStoreError.invalidArgument("blacklistRule")
    }
    self.id = id
    self.executable = executable
    self.pattern = pattern
  }
}

public struct ServiceWorkspaceCommand: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let executable: String
  /// Argument prefix: raw-argv requests match when they start with this prefix
  /// (empty means any arguments are allowed for the executable).
  public let arguments: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let risk: ServiceWorkspaceCommandRisk

  public init(
    id: String,
    name: String,
    executable: String,
    arguments: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    risk: ServiceWorkspaceCommandRisk = .normal
  ) throws {
    try ServiceValidation.identifier(id, field: "workspaceCommand.id", maximumBytes: 128)
    try ServiceValidation.text(name, field: "workspaceCommand.name", maximumBytes: 256)
    try ServiceValidation.text(
      executable, field: "workspaceCommand.executable", maximumBytes: 4_096)
    guard arguments.count <= 128 else {
      throw ServiceStoreError.invalidArgument("workspaceCommand.arguments")
    }
    for (index, argument) in arguments.enumerated() {
      try ServiceValidation.text(
        argument, field: "workspaceCommand.argument.\(index)", maximumBytes: 4_096)
    }
    try ServiceValidation.optionalText(
      workingDirectory,
      field: "workspaceCommand.workingDirectory",
      maximumBytes: 1_024
    )
    self.id = id
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }

  public static func stableID(
    name: String,
    executable: String,
    arguments: [String],
    workingDirectory: String?
  ) -> String {
    let canonical = [
      name.trimmingCharacters(in: .whitespacesAndNewlines),
      executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments.joined(separator: "\u{0}"),
      workingDirectory ?? "",
    ].joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "wcmd_" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
  }
}

public struct ServiceProjectRecord: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let name: String
  public let root: ServiceRootIdentity
  public let accessPolicy: ProjectAccessPolicy
  public let directCommandMode: ServiceDirectCommandMode
  public let workspaceCommands: [ServiceWorkspaceCommand]
  public let commandBlacklist: [ServiceCommandBlacklistRule]
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: ProjectID,
    name: String,
    root: ServiceRootIdentity,
    accessPolicy: ProjectAccessPolicy,
    directCommandMode: ServiceDirectCommandMode = .safe,
    workspaceCommands: [ServiceWorkspaceCommand] = [],
    commandBlacklist: [ServiceCommandBlacklistRule] = [],
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.identifier(id.rawValue, field: "project.id", maximumBytes: 128)
    try ServiceValidation.text(name, field: "project.name", maximumBytes: 1_024)
    try ServiceValidation.projectPolicy(accessPolicy)
    guard workspaceCommands.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist.count <= 128 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    try ServiceValidation.date(createdAt, field: "project.createdAt")
    try ServiceValidation.date(updatedAt, field: "project.updatedAt")
    guard updatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("project.updatedAt")
    }
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.root = root
    self.accessPolicy = accessPolicy
    self.directCommandMode = directCommandMode
    self.workspaceCommands = workspaceCommands
    self.commandBlacklist = commandBlacklist
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func updatingAccessPolicy(
    _ policy: ProjectAccessPolicy,
    at date: Date
  ) throws -> ServiceProjectRecord {
    try ServiceProjectRecord(
      id: id,
      name: name,
      root: root,
      accessPolicy: policy,
      directCommandMode: directCommandMode,
      workspaceCommands: workspaceCommands,
      commandBlacklist: commandBlacklist,
      createdAt: createdAt,
      updatedAt: date
    )
  }

  public func updatingWorkspaceConfiguration(
    directCommandMode: ServiceDirectCommandMode,
    workspaceCommands: [ServiceWorkspaceCommand],
    commandBlacklist: [ServiceCommandBlacklistRule],
    at date: Date
  ) throws -> ServiceProjectRecord {
    try ServiceProjectRecord(
      id: id,
      name: name,
      root: root,
      accessPolicy: accessPolicy,
      directCommandMode: directCommandMode,
      workspaceCommands: workspaceCommands,
      commandBlacklist: commandBlacklist,
      createdAt: createdAt,
      updatedAt: date
    )
  }
}
