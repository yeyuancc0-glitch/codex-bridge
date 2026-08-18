import Foundation

public struct CodexClientInfo: Codable, Equatable, Sendable {
  public let name: String
  public let title: String?
  public let version: String

  public init(name: String, title: String?, version: String) {
    self.name = name
    self.title = title
    self.version = version
  }

  public static func bridge(version: String) -> CodexClientInfo {
    CodexClientInfo(
      name: "codex_bridge_macos",
      title: "Codex Bridge for macOS",
      version: version
    )
  }
}

public struct InitializeCapabilities: Codable, Equatable, Sendable {
  public let experimentalAPI: Bool
  public let requestAttestation: Bool

  public init() {
    experimentalAPI = false
    requestAttestation = false
  }

  private enum CodingKeys: String, CodingKey {
    case experimentalAPI = "experimentalApi"
    case requestAttestation
  }
}

struct InitializeParams: Codable, Equatable, Sendable {
  let clientInfo: CodexClientInfo
  let capabilities: InitializeCapabilities
}

public struct InitializeResponse: Codable, Equatable, Sendable {
  public let userAgent: String
  public let codexHome: String
  public let platformFamily: String
  public let platformOS: String

  private enum CodingKeys: String, CodingKey {
    case userAgent
    case codexHome
    case platformFamily
    case platformOS = "platformOs"
  }
}

public struct ModelListParams: Codable, Equatable, Sendable {
  public let cursor: String?
  public let limit: UInt32?
  public let includeHidden: Bool?

  public init(
    cursor: String? = nil,
    limit: UInt32? = nil,
    includeHidden: Bool? = nil
  ) {
    self.cursor = cursor
    self.limit = limit
    self.includeHidden = includeHidden
  }
}

public struct ReasoningEffortOption: Codable, Equatable, Sendable {
  public let reasoningEffort: String
  public let description: String
}

public struct ModelServiceTier: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
}

public struct CodexModel: Codable, Equatable, Sendable {
  public let id: String
  public let model: String
  public let displayName: String
  public let description: String
  public let hidden: Bool
  public let supportedReasoningEfforts: [ReasoningEffortOption]
  public let defaultReasoningEffort: String
  public let isDefault: Bool

  public let upgrade: String?
  public let upgradeInfo: JSONValue?
  public let availabilityNux: JSONValue?
  public let inputModalities: [String]?
  public let supportsPersonality: Bool?
  public let additionalSpeedTiers: [String]?
  public let serviceTiers: [ModelServiceTier]?
  public let defaultServiceTier: String?
}

public struct ModelListResponse: Codable, Equatable, Sendable {
  public let data: [CodexModel]
  public let nextCursor: String?
}

extension CodexModel {
  public var supportsFastMode: Bool {
    additionalSpeedTiers?.contains("fast") == true
      || serviceTiers?.contains(where: { $0.id == "fast" }) == true
  }

  public var fastServiceTierID: String? {
    guard supportsFastMode else { return nil }
    return serviceTiers?.first(where: { $0.id == "fast" })?.id
      ?? serviceTiers?.first?.id
      ?? "fast"
  }
}
