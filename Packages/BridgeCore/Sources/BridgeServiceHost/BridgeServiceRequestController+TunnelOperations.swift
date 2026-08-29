import BridgeIPC
import BridgeTunnel
import Foundation

extension BridgeServiceRequestController {
  func handleConfigureTunnel(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCTunnelConfigurationRequest.self,
      from: request
    )
    let status = try await composition.configureTunnel(
      tunnelID: payload.tunnelID,
      runtimeKey: payload.runtimeKey
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.tunnelStatus(status)
    )
  }

  func handleConnectTunnel(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let status = try await composition.connectTunnel()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.tunnelStatus(status)
    )
  }

  func handleDisconnectTunnel(_ request: BridgeServiceIPCRequest) async throws -> Data {
    try await composition.disconnectTunnel()
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleClearTunnel(_ request: BridgeServiceIPCRequest) async throws -> Data {
    try await composition.clearTunnelConfiguration()
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
