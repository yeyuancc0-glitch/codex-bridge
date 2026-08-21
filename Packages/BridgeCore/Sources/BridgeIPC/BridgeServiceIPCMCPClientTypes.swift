import BridgeMCP
import Foundation

public struct IPCMCPClientStatus: Codable, Equatable, Sendable {
  public let clientID: String
  public let displayName: String
  public let enabled: Bool
  public let exposureMode: MCPServiceExposureMode
  public let activeSessionCount: Int
  public let lastConnectedAt: String?

  public init(
    clientID: String,
    displayName: String,
    enabled: Bool,
    exposureMode: MCPServiceExposureMode,
    activeSessionCount: Int,
    lastConnectedAt: String? = nil
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.enabled = enabled
    self.exposureMode = exposureMode
    self.activeSessionCount = activeSessionCount
    self.lastConnectedAt = lastConnectedAt
  }

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case displayName = "display_name"
    case enabled
    case exposureMode = "exposure_mode"
    case activeSessionCount = "active_session_count"
    case lastConnectedAt = "last_connected_at"
  }
}

public struct IPCMCPClientListResponse: Codable, Equatable, Sendable {
  public let clients: [IPCMCPClientStatus]

  public init(clients: [IPCMCPClientStatus]) {
    self.clients = clients
  }
}

public struct IPCMCPClientRequest: Codable, Equatable, Sendable {
  public let clientID: String

  public init(clientID: String) {
    self.clientID = clientID
  }

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

public struct IPCMCPClientEnabledRequest: Codable, Equatable, Sendable {
  public let clientID: String
  public let enabled: Bool

  public init(clientID: String, enabled: Bool) {
    self.clientID = clientID
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case enabled
  }
}

public struct IPCMCPClientExposureRequest: Codable, Equatable, Sendable {
  public let clientID: String
  public let exposureMode: MCPServiceExposureMode

  public init(clientID: String, exposureMode: MCPServiceExposureMode) {
    self.clientID = clientID
    self.exposureMode = exposureMode
  }

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case exposureMode = "exposure_mode"
  }
}

public struct IPCMCPClientConfigurationExport: Codable, Equatable, Sendable {
  public let configurationJSON: String

  public init(configurationJSON: String) {
    self.configurationJSON = configurationJSON
  }

  private enum CodingKeys: String, CodingKey {
    case configurationJSON = "configuration_json"
  }
}

public struct IPCLocalMCPEndpointResponse: Codable, Equatable, Sendable {
  public let localMCPURL: String

  public init(localMCPURL: String) {
    self.localMCPURL = localMCPURL
  }

  private enum CodingKeys: String, CodingKey {
    case localMCPURL = "local_mcp_url"
  }
}
