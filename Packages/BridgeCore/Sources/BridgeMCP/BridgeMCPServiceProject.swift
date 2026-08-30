import Foundation

public struct MCPProjectCommand: Codable, Equatable, Sendable {
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
public struct MCPProjectCommands: Codable, Equatable, Sendable {
  public let commandMode: String
  public let builtInCommands: [MCPBuiltInCommand]
  public let commands: [MCPProjectCommand]
  public let recommendedUsage: [String: MCPRecommendedCommandUsage]

  public init(
    commandMode: String,
    builtInCommands: [MCPBuiltInCommand] = [],
    commands: [MCPProjectCommand],
    recommendedUsage: [String: MCPRecommendedCommandUsage] = [:]
  ) {
    self.commandMode = commandMode
    self.builtInCommands = builtInCommands
    self.commands = commands
    self.recommendedUsage = recommendedUsage
  }

  private enum CodingKeys: String, CodingKey {
    case commandMode = "command_mode"
    case builtInCommands = "built_in_commands"
    case commands
    case recommendedUsage = "recommended_usage"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    commandMode = try container.decode(String.self, forKey: .commandMode)
    builtInCommands =
      try container.decodeIfPresent([MCPBuiltInCommand].self, forKey: .builtInCommands) ?? []
    commands = try container.decode([MCPProjectCommand].self, forKey: .commands)
    recommendedUsage =
      try container.decodeIfPresent(
        [String: MCPRecommendedCommandUsage].self,
        forKey: .recommendedUsage
      ) ?? [:]
  }
}

public struct MCPRecommendedCommandUsage: Codable, Equatable, Sendable {
  public let commandID: String?
  public let argv: [String]
  public let workingDirectory: String?

  public init(commandID: String? = nil, argv: [String], workingDirectory: String? = nil) {
    self.commandID = commandID
    self.argv = argv
    self.workingDirectory = workingDirectory
  }

  private enum CodingKeys: String, CodingKey {
    case commandID = "command_id"
    case argv
    case workingDirectory = "working_directory"
  }
}

public struct MCPBuiltInCommand: Codable, Equatable, Sendable {
  public let executable: String
  public let argumentsPrefix: [String]
  public let allowsAdditionalArguments: Bool
  public let requiresNetwork: Bool

  public init(
    executable: String,
    argumentsPrefix: [String],
    allowsAdditionalArguments: Bool = true,
    requiresNetwork: Bool = false
  ) {
    self.executable = executable
    self.argumentsPrefix = argumentsPrefix
    self.allowsAdditionalArguments = allowsAdditionalArguments
    self.requiresNetwork = requiresNetwork
  }

  private enum CodingKeys: String, CodingKey {
    case executable
    case argumentsPrefix = "arguments_prefix"
    case allowsAdditionalArguments = "allows_additional_arguments"
    case requiresNetwork = "requires_network"
  }
}

public struct MCPProjectChanges: Codable, Equatable, Sendable {
  public let changedFiles: [String]
  public let diff: String
  public let additions: Int
  public let deletions: Int
  public let truncated: Bool
  public let notGitRepository: Bool

  public init(
    changedFiles: [String],
    diff: String,
    additions: Int,
    deletions: Int,
    truncated: Bool,
    notGitRepository: Bool
  ) {
    self.changedFiles = changedFiles
    self.diff = diff
    self.additions = additions
    self.deletions = deletions
    self.truncated = truncated
    self.notGitRepository = notGitRepository
  }

  private enum CodingKeys: String, CodingKey {
    case changedFiles = "changed_files"
    case diff
    case additions
    case deletions
    case truncated
    case notGitRepository = "not_git_repository"
  }
}
