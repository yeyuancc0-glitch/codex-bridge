import Foundation

public enum SkillScope: String, Codable, Sendable {
  case project
  case global
}

public enum SkillActionNetworkRequirement: String, Codable, Equatable, Sendable {
  /// The action explicitly declares that it must not access the network.
  case denied
  /// The action explicitly declares that it needs network access.
  case required
  /// Compatibility discovery found an entrypoint, but its network behavior is unknown.
  case unspecified
}

public struct SkillAction: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  /// Action name referenced by `run_skill_action`.
  public let name: String
  /// Project-relative path to the script inside the Skill root.
  public let scriptPath: String
  /// Interpreter used to launch the script (e.g. `node`, `python3`), or `nil`
  /// when the script carries a valid shebang and can be launched directly.
  public let interpreter: String?
  public let networkRequirement: SkillActionNetworkRequirement
  /// Backward-compatible capability projection. Unspecified actions are treated
  /// as network-capable so project policy and local approval remain enforced.
  public var requiresNetwork: Bool { networkRequirement != .denied }
  public let description: String

  public init(
    name: String,
    scriptPath: String,
    interpreter: String?,
    requiresNetwork: Bool,
    description: String = ""
  ) {
    self.name = name
    self.scriptPath = scriptPath
    self.interpreter = interpreter
    networkRequirement = requiresNetwork ? .required : .denied
    self.description = description
  }

  public init(
    name: String,
    scriptPath: String,
    interpreter: String?,
    networkRequirement: SkillActionNetworkRequirement,
    description: String = ""
  ) {
    self.name = name
    self.scriptPath = scriptPath
    self.interpreter = interpreter
    self.networkRequirement = networkRequirement
    self.description = description
  }
}

public struct SkillManifest: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let description: String
  public let scope: SkillScope
  public let rootPath: String
  public let triggers: [String]
  public let actions: [SkillAction]
  public let hasReferences: Bool

  public init(
    name: String,
    description: String,
    scope: SkillScope,
    rootPath: String,
    triggers: [String] = [],
    actions: [SkillAction] = [],
    hasReferences: Bool = false
  ) {
    self.name = name
    self.description = description
    self.scope = scope
    self.rootPath = rootPath
    self.triggers = triggers
    self.actions = actions
    self.hasReferences = hasReferences
  }
}

public struct SkillDocument: Codable, Equatable, Sendable {
  public let name: String
  public let subpath: String
  public let content: String
  public let byteCount: Int

  public init(name: String, subpath: String, content: String, byteCount: Int) {
    self.name = name
    self.subpath = subpath
    self.content = content
    self.byteCount = byteCount
  }
}

public enum SkillError: Error, Equatable, Sendable {
  case invalidSkillName
  case invalidManifest
  case pathEscapeDetected
  case sensitivePath
  case documentNotFound
  case documentTooLarge
  case invalidEncoding
  case tooManySkills
  case actionNotFound
  case actionNotRunnable
  case networkIsolationUnavailable
}
