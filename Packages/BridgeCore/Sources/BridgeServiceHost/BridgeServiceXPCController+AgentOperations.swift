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

extension BridgeServiceXPCController {
  func handleSubmitAgentTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentSubmitRequest.self, from: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    let result = try await composition.application.serviceSubmitAgentTask(
      projectID: payload.projectID,
      providerID: payload.providerID,
      installationID: payload.installationID,
      model: payload.model,
      permissionMode: payload.permissionMode,
      prompt: payload.prompt,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentSubmitResponse(taskID: result.taskID, status: result.status)
    )
  }

  func handleListAgentModels(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentModelsRequest.self, from: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    let items = try await composition.application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelsResponse(
        models: items.map { IPCAgentModelSummary(modelID: $0.modelID, displayName: $0.displayName) }
      )
    )
  }
}

extension BridgeServiceXPCController {
  func handleGetAgentModelDefault(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let model = try await composition.application.serviceOpenCodeDefaultModel(deadline: deadline)
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelDefaultResponse(model: model)
    )
  }

  func handleSetAgentModelDefault(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentModelDefaultRequest.self, from: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    try await composition.application.serviceSetOpenCodeDefaultModel(
      payload.model,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelDefaultResponse(model: payload.model)
    )
  }
}
