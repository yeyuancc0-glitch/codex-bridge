import BridgeAgentCore
import BridgeIPC
import BridgeOpenCodeACP
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleGetAgentCatalog(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let deadline = Self.deadline()
    let providers = try await composition.application.serviceManagedAgentProviderDescriptors(
      deadline: deadline
    )
    let installations = try await composition.application.serviceManagedAgentInstallations(
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentCatalogResponse(
        providers: providers.map(Self.agentProviderSummary),
        installations: installations.map(Self.agentInstallationSummary)
      )
    )
  }

  func handleRegisterAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentRegistrationRequest.self,
      from: request
    )
    let providerID = AgentProviderID(rawValue: payload.providerID)
    let securityProfileID: AgentProfileID? =
      providerID == .openCode ? OpenCodeACPProfiles.controlledReadOnly : nil
    let record = try await composition.application.serviceRegisterManagedAgent(
      try ServiceAgentRegistrationRequest(
        providerID: providerID,
        displayName: payload.displayName,
        executablePath: payload.executablePath,
        trustProfile: .managed,
        securityProfileID: securityProfileID,
        enableOnSuccess: false
      ),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleReprobeAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentReprobeRequest.self,
      from: request
    )
    let record = try await composition.application.serviceReprobeManagedAgent(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      acceptReplacement: payload.acceptReplacement,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleSetAgentInstallationEnabled(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentEnabledRequest.self,
      from: request
    )
    let record = try await composition.application.serviceSetManagedAgentEnabled(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      enabled: payload.enabled,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleRemoveAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentInstallationIDRequest.self,
      from: request
    )
    try await composition.application.serviceRemoveManagedAgent(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  private static func agentProviderSummary(
    _ descriptor: AgentProviderDescriptor
  ) -> IPCAgentProviderSummary {
    IPCAgentProviderSummary(
      providerID: descriptor.providerID.rawValue,
      displayName: descriptor.displayName,
      adapterRevision: descriptor.adapterRevision
    )
  }

  private static func agentInstallationSummary(
    _ record: ServiceAgentInstallationRecord
  ) -> IPCAgentInstallationSummary {
    let formatter = ISO8601DateFormatter()
    return IPCAgentInstallationSummary(
      installationID: record.id.rawValue,
      providerID: record.providerID.rawValue,
      displayName: record.displayName,
      executablePath: record.executablePath,
      version: record.version,
      protocolRevision: record.protocolRevision,
      adapterRevision: record.adapterRevision,
      trustProfile: record.trustProfile.rawValue,
      securityProfileID: record.securityProfileID?.rawValue,
      isEnabled: record.isEnabled,
      availability: record.availability.rawValue,
      effectiveCapabilities: record.capabilities.effective
        .map(\.rawValue)
        .sorted(),
      lastProbeError: record.lastProbeError,
      lastProbedAt: record.lastProbedAt.map(formatter.string(from:)),
      updatedAt: formatter.string(from: record.updatedAt)
    )
  }
}
