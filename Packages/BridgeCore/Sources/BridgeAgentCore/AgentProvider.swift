import Foundation

public struct AgentProviderDescriptor: Codable, Equatable, Sendable {
  public let providerID: AgentProviderID
  public let displayName: String
  public let adapterRevision: Int

  public init(providerID: AgentProviderID, displayName: String, adapterRevision: Int) throws {
    guard adapterRevision > 0 else {
      throw AgentRuntimeError.invalidRequest("provider.adapterRevision")
    }
    try AgentValidation.identifier(
      providerID.rawValue,
      field: "provider.providerID",
      maximumBytes: 128
    )
    try AgentValidation.text(displayName, field: "provider.displayName", maximumBytes: 256)
    self.providerID = providerID
    self.displayName = displayName
    self.adapterRevision = adapterRevision
  }
}

public struct AgentInstallation: Codable, Equatable, Sendable {
  public let id: AgentInstallationID
  public let providerID: AgentProviderID
  public let executablePath: String
  public let version: String?
  public let protocolRevision: String?
  public let artifacts: [AgentInstallationArtifact]

  public init(
    id: AgentInstallationID,
    providerID: AgentProviderID,
    executablePath: String,
    version: String? = nil,
    protocolRevision: String? = nil,
    artifacts: [AgentInstallationArtifact] = []
  ) throws {
    try AgentValidation.identifier(id.rawValue, field: "installation.id", maximumBytes: 256)
    try AgentValidation.identifier(
      providerID.rawValue,
      field: "installation.providerID",
      maximumBytes: 128
    )
    try AgentValidation.absolutePath(executablePath, field: "installation.executablePath")
    try AgentValidation.optionalIdentifier(
      version,
      field: "installation.version",
      maximumBytes: 256
    )
    try AgentValidation.optionalIdentifier(
      protocolRevision,
      field: "installation.protocolRevision",
      maximumBytes: 128
    )
    guard artifacts.count <= 16,
      Set(artifacts.map(\.role)).count == artifacts.count,
      artifacts.allSatisfy({
        $0.canonicalPath.hasPrefix("/")
          && $0.canonicalPath.utf8.count <= 16 * 1_024
          && !$0.canonicalPath.contains("\0")
          && $0.inode > 0
          && $0.fileSize > 0
          && $0.modificationTimeNanoseconds >= 0
          && $0.sha256.utf8.count == 64
          && $0.sha256.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
          }
      })
    else {
      throw AgentRuntimeError.invalidRequest("installation.artifacts")
    }
    self.id = id
    self.providerID = providerID
    self.executablePath = executablePath
    self.version = version
    self.protocolRevision = protocolRevision
    self.artifacts = artifacts
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case providerID
    case executablePath
    case version
    case protocolRevision
    case artifacts
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(AgentInstallationID.self, forKey: .id),
      providerID: container.decode(AgentProviderID.self, forKey: .providerID),
      executablePath: container.decode(String.self, forKey: .executablePath),
      version: container.decodeIfPresent(String.self, forKey: .version),
      protocolRevision: container.decodeIfPresent(String.self, forKey: .protocolRevision),
      artifacts: container.decodeIfPresent(
        [AgentInstallationArtifact].self,
        forKey: .artifacts
      ) ?? []
    )
  }
}

public struct AgentProbeRequest: Equatable, Sendable {
  public let installation: AgentInstallation
  public let projectRoot: String?

  public init(installation: AgentInstallation, projectRoot: String? = nil) throws {
    if let projectRoot {
      try AgentValidation.absolutePath(projectRoot, field: "probe.projectRoot")
    }
    self.installation = installation
    self.projectRoot = projectRoot
  }
}

public struct AgentProbeResult: Equatable, Sendable {
  public let installation: AgentInstallation
  public let available: Bool
  public let reviewRequired: Bool
  public let capabilities: AgentCapabilitySnapshot
  public let unavailableReason: String?

  public init(
    installation: AgentInstallation,
    available: Bool,
    reviewRequired: Bool = false,
    capabilities: AgentCapabilitySnapshot,
    unavailableReason: String? = nil
  ) {
    self.installation = installation
    self.available = available
    self.reviewRequired = !available && reviewRequired
    self.capabilities = capabilities
    if available {
      self.unavailableReason = nil
    } else {
      let value = unavailableReason?.replacingOccurrences(of: "\0", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      self.unavailableReason =
        value.flatMap { text in
          text.isEmpty ? nil : String(text.prefix(4 * 1_024))
        } ?? "Provider unavailable."
    }
  }
}

public struct AgentModelDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let supportedReasoningEfforts: [String]
  public let defaultReasoningEffort: String?

  public init(
    id: String,
    displayName: String,
    supportedReasoningEfforts: [String] = [],
    defaultReasoningEffort: String? = nil
  ) throws {
    try AgentValidation.identifier(id, field: "model.id", maximumBytes: 256)
    try AgentValidation.text(displayName, field: "model.displayName", maximumBytes: 512)
    guard supportedReasoningEfforts.count <= 64,
      Set(supportedReasoningEfforts).count == supportedReasoningEfforts.count
    else {
      throw AgentRuntimeError.invalidRequest("model.reasoningEfforts")
    }
    for effort in supportedReasoningEfforts {
      try AgentValidation.identifier(effort, field: "model.reasoningEffort", maximumBytes: 64)
    }
    if let defaultReasoningEffort {
      try AgentValidation.identifier(
        defaultReasoningEffort,
        field: "model.defaultReasoningEffort",
        maximumBytes: 64
      )
      guard supportedReasoningEfforts.contains(defaultReasoningEffort) else {
        throw AgentRuntimeError.invalidRequest("model.defaultReasoningEffort")
      }
    }
    self.id = id
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case supportedReasoningEfforts
    case defaultReasoningEffort
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      displayName: container.decode(String.self, forKey: .displayName),
      supportedReasoningEfforts: container.decodeIfPresent(
        [String].self,
        forKey: .supportedReasoningEfforts
      ) ?? [],
      defaultReasoningEffort: container.decodeIfPresent(
        String.self,
        forKey: .defaultReasoningEffort
      )
    )
  }
}

public protocol AgentProvider: Sendable {
  var descriptor: AgentProviderDescriptor { get }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult

  func models(
    installation: AgentInstallation,
    projectRoot: String?
  ) async throws -> [AgentModelDescriptor]

  func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor]

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle
}

extension AgentProvider {
  public func models(
    installation _: AgentInstallation,
    projectRoot _: String?
  ) async throws -> [AgentModelDescriptor] {
    throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
  }

  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID _: String?
  ) async throws -> [AgentModelDescriptor] {
    try await models(installation: installation, projectRoot: projectRoot)
  }
}
