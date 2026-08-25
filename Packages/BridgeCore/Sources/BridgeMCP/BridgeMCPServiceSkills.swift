import BridgeSkills
import Foundation

public struct MCPServiceSkillAction: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let scriptPath: String
  public let interpreter: String?
  public let commandPrefix: [String]?
  public let requiresNetwork: Bool
  public let networkRequirement: SkillActionNetworkRequirement
  public let description: String

  public init(action: SkillAction) {
    name = action.name
    scriptPath = action.scriptPath
    interpreter = action.interpreter
    commandPrefix = action.commandPrefix
    requiresNetwork = action.requiresNetwork
    networkRequirement = action.networkRequirement
    description = action.description
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case scriptPath = "script_path"
    case interpreter
    case commandPrefix = "command_prefix"
    case requiresNetwork = "requires_network"
    case networkRequirement = "network_requirement"
    case description
  }
}
public struct MCPServiceSkill: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let description: String
  public let scope: SkillScope
  public let triggers: [String]
  public let actions: [MCPServiceSkillAction]
  public let hasReferences: Bool

  public init(manifest: SkillManifest) {
    name = manifest.name
    description = manifest.description
    scope = manifest.scope
    triggers = manifest.triggers
    actions = manifest.actions.map(MCPServiceSkillAction.init)
    hasReferences = manifest.hasReferences
  }

  private enum CodingKeys: String, CodingKey {
    case name, description, scope, triggers
    case actions
    case hasReferences = "has_references"
  }
}

public struct MCPServiceSkillList: Codable, Equatable, Sendable {
  public let skills: [MCPServiceSkill]
  public init(skills: [MCPServiceSkill]) { self.skills = skills }
}

public struct MCPServiceSkillDocument: Codable, Equatable, Sendable {
  public let name: String
  public let subpath: String
  public let content: String
  public let byteCount: Int

  public init(document: SkillDocument) {
    name = document.name
    subpath = document.subpath
    content = document.content
    byteCount = document.byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case name, subpath, content
    case byteCount = "byte_count"
  }

}

public struct MCPRunSkillActionRequest: Codable, Equatable, Sendable {
  public let skillName: String
  public let actionName: String
  public let arguments: [String]
  public let projectID: String
  public let yieldTimeMS: Int
  public let timeoutMS: Int
  public let clientRequestID: String?

  public init(
    skillName: String,
    actionName: String,
    arguments: [String] = [],
    projectID: String,
    yieldTimeMS: Int = 15_000,
    timeoutMS: Int = 300_000,
    clientRequestID: String? = nil
  ) {
    self.skillName = skillName
    self.actionName = actionName
    self.arguments = arguments
    self.projectID = projectID
    self.yieldTimeMS = yieldTimeMS
    self.timeoutMS = timeoutMS
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case skillName = "skill_name"
    case actionName = "action_name"
    case arguments
    case projectID = "project_id"
    case yieldTimeMS = "yield_time_ms"
    case timeoutMS = "timeout_ms"
    case clientRequestID = "client_request_id"
  }
}
