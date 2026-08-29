import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension BridgeServiceRequestController {
  static func tunnelStatus(
    _ snapshot: ServiceTunnelSnapshot
  ) -> IPCTunnelStatus {
    IPCTunnelStatus(
      configured: snapshot.configured,
      enabled: snapshot.enabled,
      helperAvailable: snapshot.helperAvailable,
      tunnelID: snapshot.tunnelID,
      lifecycle: snapshot.lifecycle.rawValue,
      acceptsRemoteSubmissions: snapshot.acceptsRemoteSubmissions,
      actionRequired: snapshot.actionRequired
    )
  }

  static func mcpExposureMode(
    _ mode: ServiceMCPExposureMode
  ) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }
}
