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

  public init(
    id: AgentInstallationID,
    providerID: AgentProviderID,
    executablePath: String,
    version: String? = nil,
    protocolRevision: String? = nil
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
    self.id = id
    self.providerID = providerID
    self.executablePath = executablePath
    self.version = version
    self.protocolRevision = protocolRevision
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

public protocol AgentProvider: Sendable {
  var descriptor: AgentProviderDescriptor { get }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle
}
