import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceRequestController {
  func handleListMCPClients(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let formatter = ISO8601DateFormatter()
    let statuses = try await composition.mcpClientStatuses()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCMCPClientListResponse(
        clients: statuses.map { status in
          IPCMCPClientStatus(
            clientID: status.profile.clientID.rawValue,
            displayName: status.profile.displayName,
            enabled: status.profile.enabled,
            exposureMode: status.profile.exposureMode,
            activeSessionCount: status.activeSessionCount,
            lastConnectedAt: status.lastConnectedAt.map(formatter.string(from:))
          )
        }
      )
    )
  }

  func handleSetMCPClientEnabled(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCMCPClientEnabledRequest.self,
      from: request
    )
    guard payload.clientID == MCPClientID.qwenStudio.rawValue else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    try await composition.setQwenStudioEnabled(payload.enabled)
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleSetMCPClientExposureMode(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCMCPClientExposureRequest.self,
      from: request
    )
    switch payload.clientID {
    case MCPClientID.chatGPT.rawValue:
      _ = try await composition.setExposureMode(payload.exposureMode)
    case MCPClientID.qwenStudio.rawValue:
      try await composition.setQwenStudioExposureMode(payload.exposureMode)
    default:
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleExportMCPClientConfiguration(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCMCPClientRequest.self, from: request)
    guard payload.clientID == MCPClientID.qwenStudio.rawValue else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    let configuration = try await composition.exportQwenStudioConfiguration()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCMCPClientConfigurationExport(configurationJSON: configuration)
    )
  }

  func handleRotateMCPClientCredential(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCMCPClientRequest.self, from: request)
    guard payload.clientID == MCPClientID.qwenStudio.rawValue else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    try await composition.rotateQwenStudioCredential()
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleRotateLocalMCPEndpoint(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let endpoint = try await composition.rotateLocalMCPEndpoint()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCLocalMCPEndpointResponse(localMCPURL: endpoint.localURL.absoluteString)
    )
  }
}
