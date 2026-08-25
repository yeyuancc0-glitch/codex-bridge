import Foundation

public protocol AgentStringIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {}

public struct AgentProviderID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let codex = AgentProviderID(rawValue: "codex")
  public static let openCode = AgentProviderID(rawValue: "opencode")
}

public struct AgentInstallationID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct AgentProfileID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
