import BridgeMCP
import Foundation

public struct IPCProjectRegistrationRequest: Codable, Equatable, Sendable {
  public let name: String
  public let absolutePath: String
  public let readPermission: String
  public let writePermission: String
  public let networkPermission: String

  public init(
    name: String,
    absolutePath: String,
    readPermission: String = "allowed",
    writePermission: String = "requiresLocalApproval",
    networkPermission: String = "denied"
  ) {
    self.name = name
    self.absolutePath = absolutePath
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case absolutePath = "absolute_path"
    case readPermission = "read_permission"
    case writePermission = "write_permission"
    case networkPermission = "network_permission"
  }
}

public struct IPCProjectPolicyRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let readPermission: String
  public let writePermission: String
  public let networkPermission: String

  public init(
    projectID: String,
    readPermission: String,
    writePermission: String,
    networkPermission: String
  ) {
    self.projectID = projectID
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case readPermission = "read_permission"
    case writePermission = "write_permission"
    case networkPermission = "network_permission"
  }
}

public struct IPCProjectCommandsRequest: Codable, Equatable, Sendable {
  public let projectID: String

  public init(projectID: String) {
    self.projectID = projectID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
  }
}

public struct IPCProjectSkillsRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public init(projectID: String) { self.projectID = projectID }
  private enum CodingKeys: String, CodingKey { case projectID = "project_id" }
}

public struct IPCWorkspaceCommand: Codable, Equatable, Sendable {
  public let commandID: String
  public let name: String
  public let executable: String
  public let arguments: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let risk: String

  public init(
    commandID: String,
    name: String,
    executable: String,
    arguments: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    risk: String = "normal"
  ) {
    self.commandID = commandID
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }

  private enum CodingKeys: String, CodingKey {
    case commandID = "command_id"
    case name
    case executable
    case arguments
    case workingDirectory = "working_directory"
    case requiresNetwork = "requires_network"
    case risk
  }
}

public struct IPCBlacklistRule: Codable, Equatable, Sendable {
  public let ruleID: String
  public let executable: String?
  public let pattern: String?

  public init(ruleID: String, executable: String? = nil, pattern: String? = nil) {
    self.ruleID = ruleID
    self.executable = executable
    self.pattern = pattern
  }

  private enum CodingKeys: String, CodingKey {
    case ruleID = "rule_id"
    case executable
    case pattern
  }
}

public struct IPCProjectCommandsUpdateRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let commands: [IPCWorkspaceCommand]
  public let commandBlacklist: [IPCBlacklistRule]

  public init(
    projectID: String,
    commands: [IPCWorkspaceCommand],
    commandBlacklist: [IPCBlacklistRule] = []
  ) {
    self.projectID = projectID
    self.commands = commands
    self.commandBlacklist = commandBlacklist
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case commands
    case commandBlacklist = "command_blacklist"
  }
}

public struct IPCProjectCommandModeUpdateRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let commandMode: String

  public init(projectID: String, commandMode: String) {
    self.projectID = projectID
    self.commandMode = commandMode
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case commandMode = "command_mode"
  }
}

public struct IPCProjectCommandsResponse: Codable, Equatable, Sendable {
  public let project: MCPProjectDetail

  public init(project: MCPProjectDetail) {
    self.project = project
  }

  private enum CodingKeys: String, CodingKey {
    case project
  }
}

public struct IPCProjectIDRequest: Codable, Equatable, Sendable {
  public let projectID: String

  public init(projectID: String) {
    self.projectID = projectID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
  }
}

public struct IPCWorkbenchProjectRequest: Codable, Equatable, Sendable {
  public let projectID: String?

  public init(projectID: String?) {
    self.projectID = projectID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
  }
}

public struct IPCProjectListResponse: Codable, Equatable, Sendable {
  public let projects: [MCPProjectSummary]

  public init(projects: [MCPProjectSummary]) {
    self.projects = projects
  }
}
