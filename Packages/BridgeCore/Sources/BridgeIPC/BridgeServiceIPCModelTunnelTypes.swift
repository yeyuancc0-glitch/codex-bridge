import BridgeMCP
import Foundation

public struct IPCExposureModeRequest: Codable, Equatable, Sendable {
  public let exposureMode: MCPServiceExposureMode

  public init(exposureMode: MCPServiceExposureMode) {
    self.exposureMode = exposureMode
  }

  private enum CodingKeys: String, CodingKey {
    case exposureMode = "exposure_mode"
  }
}

public struct IPCModelPreferences: Codable, Equatable, Sendable {
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String
  public let supervisorEffort: String
  public let supervisorEnabled: Bool
  public let accessMode: String
  public let fastModeEnabled: Bool

  #if os(Windows)
    public static let defaultSupervisorEnabled = false
  #else
    public static let defaultSupervisorEnabled = true
  #endif

  public init(
    executionModel: String,
    executionEffort: String,
    supervisorModel: String,
    supervisorEffort: String,
    supervisorEnabled: Bool = Self.defaultSupervisorEnabled,
    accessMode: String = "request-approval",
    fastModeEnabled: Bool = false
  ) {
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.supervisorEnabled = supervisorEnabled
    self.accessMode = accessMode
    self.fastModeEnabled = fastModeEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case supervisorModel = "supervisor_model"
    case supervisorEffort = "supervisor_effort"
    case supervisorEnabled = "supervisor_enabled"
    case accessMode = "access_mode"
    case fastModeEnabled = "fast_mode_enabled"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.executionModel = try values.decode(String.self, forKey: .executionModel)
    self.executionEffort = try values.decode(String.self, forKey: .executionEffort)
    self.supervisorModel = try values.decode(String.self, forKey: .supervisorModel)
    self.supervisorEffort = try values.decode(String.self, forKey: .supervisorEffort)
    self.supervisorEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .supervisorEnabled)
      ?? Self.defaultSupervisorEnabled
    self.accessMode =
      try values.decodeIfPresent(String.self, forKey: .accessMode) ?? "request-approval"
    self.fastModeEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .fastModeEnabled) ?? false
  }
}

public struct IPCSupervisorEnabledRequest: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct IPCDirectApprovalModeRequest: Codable, Equatable, Sendable {
  public let mode: String

  public init(mode: String) {
    self.mode = mode
  }
}

public struct IPCDirectApprovalModeResponse: Codable, Equatable, Sendable {
  public let mode: String

  public init(mode: String) {
    self.mode = mode
  }
}

public struct IPCTaskStartApprovalModeRequest: Codable, Equatable, Sendable {
  public let mode: String

  public init(mode: String) {
    self.mode = mode
  }
}

public struct IPCTaskStartApprovalModeResponse: Codable, Equatable, Sendable {
  public let mode: String

  public init(mode: String) {
    self.mode = mode
  }
}

public struct IPCModelCatalogResponse: Codable, Equatable, Sendable {
  public let models: [MCPModelSummary]
  public let preferences: IPCModelPreferences

  public init(models: [MCPModelSummary], preferences: IPCModelPreferences) {
    self.models = models
    self.preferences = preferences
  }
}

public struct IPCTunnelConfigurationRequest: Codable, Equatable, Sendable {
  public let tunnelID: String
  public let runtimeKey: String

  public init(tunnelID: String, runtimeKey: String) {
    self.tunnelID = tunnelID
    self.runtimeKey = runtimeKey
  }

  private enum CodingKeys: String, CodingKey {
    case tunnelID = "tunnel_id"
    case runtimeKey = "runtime_key"
  }
}

public struct IPCTunnelStatus: Codable, Equatable, Sendable {
  public let configured: Bool
  public let enabled: Bool
  public let helperAvailable: Bool
  public let tunnelID: String?
  public let lifecycle: String
  public let acceptsRemoteSubmissions: Bool
  public let actionRequired: Bool

  public init(
    configured: Bool,
    enabled: Bool,
    helperAvailable: Bool,
    tunnelID: String?,
    lifecycle: String,
    acceptsRemoteSubmissions: Bool,
    actionRequired: Bool
  ) {
    self.configured = configured
    self.enabled = enabled
    self.helperAvailable = helperAvailable
    self.tunnelID = tunnelID
    self.lifecycle = lifecycle
    self.acceptsRemoteSubmissions = acceptsRemoteSubmissions
    self.actionRequired = actionRequired
  }

  private enum CodingKeys: String, CodingKey {
    case configured
    case enabled
    case helperAvailable = "helper_available"
    case tunnelID = "tunnel_id"
    case lifecycle
    case acceptsRemoteSubmissions = "accepts_remote_submissions"
    case actionRequired = "action_required"
  }
}

public struct IPCServiceStatusResponse: Codable, Equatable, Sendable {
  public let status: BridgeStatusSnapshot
  public let localMCPURL: String?
  public let exposureMode: MCPServiceExposureMode
  public let tunnel: IPCTunnelStatus
  public let workbenchProjectID: String?
  public let workbenchPermissionMode: String?

  public init(
    status: BridgeStatusSnapshot,
    localMCPURL: String?,
    exposureMode: MCPServiceExposureMode,
    tunnel: IPCTunnelStatus = .unconfigured,
    workbenchProjectID: String? = nil,
    workbenchPermissionMode: String? = nil
  ) {
    self.status = status
    self.localMCPURL = localMCPURL
    self.exposureMode = exposureMode
    self.tunnel = tunnel
    self.workbenchProjectID = workbenchProjectID
    self.workbenchPermissionMode = workbenchPermissionMode
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case localMCPURL = "local_mcp_url"
    case exposureMode = "exposure_mode"
    case tunnel
    case workbenchProjectID = "workbench_project_id"
    case workbenchPermissionMode = "workbench_permission_mode"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    status = try values.decode(BridgeStatusSnapshot.self, forKey: .status)
    localMCPURL = try values.decodeIfPresent(String.self, forKey: .localMCPURL)
    exposureMode = try values.decode(MCPServiceExposureMode.self, forKey: .exposureMode)
    tunnel =
      try values.decodeIfPresent(IPCTunnelStatus.self, forKey: .tunnel)
      ?? .unconfigured
    workbenchProjectID = try values.decodeIfPresent(String.self, forKey: .workbenchProjectID)
    workbenchPermissionMode = try values.decodeIfPresent(
      String.self,
      forKey: .workbenchPermissionMode
    )
  }
}

extension IPCTunnelStatus {
  public static let unconfigured = IPCTunnelStatus(
    configured: false,
    enabled: false,
    helperAvailable: false,
    tunnelID: nil,
    lifecycle: "stopped",
    acceptsRemoteSubmissions: false,
    actionRequired: false
  )
}
