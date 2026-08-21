import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension BridgeServiceXPCController {
  func handleStatus(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let status = try await composition.application.serviceStatus(
      deadline: Self.deadline()
    )
    let endpoint = await composition.endpoint()?.localURL.absoluteString
    let exposureMode = try await composition.application.serviceExposureMode()
    let tunnel = await composition.tunnelStatus()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCServiceStatusResponse(
        status: status,
        localMCPURL: endpoint,
        exposureMode: Self.mcpExposureMode(exposureMode),
        tunnel: Self.tunnelStatus(tunnel),
        workbenchProjectID: try await composition.application.serviceWorkbenchProjectID(
          deadline: Self.deadline()
        )
      )
    )
  }

  func handleListModels(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let models = try await composition.application.serviceModels(deadline: Self.deadline())
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: models
    )
  }

  func handleGetModelCatalog(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let catalog = try await composition.application.serviceModelCatalog(
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCModelCatalogResponse(
        models: catalog.models.models,
        preferences: IPCModelPreferences(
          executionModel: catalog.preferences.executionModel,
          executionEffort: catalog.preferences.executionEffort,
          supervisorModel: catalog.preferences.supervisorModel,
          supervisorEffort: catalog.preferences.supervisorEffort,
          supervisorEnabled: try await composition.application.serviceSupervisorEnabled(),
          accessMode: catalog.preferences.accessMode.rawValue,
          fastModeEnabled: catalog.preferences.fastModeEnabled
        )
      )
    )
  }

  func handleGetModelPreferences(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let preferences = try await composition.application.serviceModelPreferences(
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCModelPreferences(
        executionModel: preferences.executionModel,
        executionEffort: preferences.executionEffort,
        supervisorModel: preferences.supervisorModel,
        supervisorEffort: preferences.supervisorEffort,
        supervisorEnabled: try await composition.application.serviceSupervisorEnabled(),
        accessMode: preferences.accessMode.rawValue,
        fastModeEnabled: preferences.fastModeEnabled
      )
    )
  }

  func handleSetModelPreferences(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCModelPreferences.self,
      from: request
    )
    guard let accessMode = ServiceAccessMode(rawValue: payload.accessMode) else {
      throw ServiceStoreError.invalidArgument("preferences.accessMode")
    }
    try await composition.application.setServiceModelPreferences(
      ServiceModelPreferences(
        executionModel: payload.executionModel,
        executionEffort: payload.executionEffort,
        supervisorModel: payload.supervisorModel,
        supervisorEffort: payload.supervisorEffort,
        accessMode: accessMode,
        fastModeEnabled: payload.fastModeEnabled
      ),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleSetSupervisorEnabled(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCSupervisorEnabledRequest.self,
      from: request
    )
    try await composition.application.setSupervisorEnabled(payload.enabled)
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleGetDirectApprovalMode(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let mode = try await composition.application.serviceDirectApprovalMode(
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCDirectApprovalModeResponse(mode: mode.rawValue)
    )
  }

  func handleSetDirectApprovalMode(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCDirectApprovalModeRequest.self,
      from: request
    )
    guard let mode = ServiceDirectApprovalMode(rawValue: payload.mode) else {
      throw ServiceStoreError.invalidArgument("directApprovalMode")
    }
    try await composition.application.serviceSetDirectApprovalMode(
      mode,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleSetExposureMode(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCExposureModeRequest.self,
      from: request
    )
    _ = try await composition.setExposureMode(payload.exposureMode)
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
