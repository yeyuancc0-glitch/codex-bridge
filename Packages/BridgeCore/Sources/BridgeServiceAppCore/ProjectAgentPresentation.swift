import BridgeIPC
import BridgeMCP

/// Platform-neutral rows and details for the Windows project and Agent
/// management surfaces. Mutations remain owned by BridgeServiceClient.
public enum ProjectAgentPresentation {
  public struct ProjectItem: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String
    public let readPermission: String
    public let writePermission: String
    public let networkPermission: String

    public init(
      id: String,
      rowText: String,
      detailText: String,
      readPermission: String,
      writePermission: String,
      networkPermission: String
    ) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
      self.readPermission = readPermission
      self.writePermission = writePermission
      self.networkPermission = networkPermission
    }
  }

  public struct AgentProviderItem: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String
    public let requiresConfiguration: Bool

    public init(
      id: String,
      rowText: String,
      detailText: String,
      requiresConfiguration: Bool
    ) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
      self.requiresConfiguration = requiresConfiguration
    }
  }

  public struct AgentInstallationItem: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String
    public let isEnabled: Bool
    public let availability: String

    public init(
      id: String,
      rowText: String,
      detailText: String,
      isEnabled: Bool,
      availability: String
    ) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
      self.isEnabled = isEnabled
      self.availability = availability
    }
  }

  public static func project(_ project: MCPProjectSummary) -> ProjectItem {
    let git = project.gitState?.nilIfBlank ?? "未知"
    let detail = [
      "项目：\(project.name)",
      "ID：\(project.projectID)",
      "读取：\(permissionLabel(project.capabilities.read))",
      "写入：\(permissionLabel(project.capabilities.write))",
      "网络：\(permissionLabel(project.capabilities.network))",
      "Git：\(git)",
    ].joined(separator: "\r\n")
    return ProjectItem(
      id: project.projectID,
      rowText: "\(project.name) · \(project.projectID)",
      detailText: detail,
      readPermission: project.capabilities.read,
      writePermission: project.capabilities.write,
      networkPermission: project.capabilities.network
    )
  }

  public static func provider(_ provider: IPCAgentProviderSummary) -> AgentProviderItem {
    let capabilities = capabilityNames(provider).joined(separator: "、")
    let configuration = provider.requiresConfiguration ? "需要配置文件" : "无需额外配置"
    let detail = [
      "Provider：\(provider.displayName)",
      "ID：\(provider.providerID)",
      "Adapter：r\(provider.adapterRevision)",
      "注册：\(provider.registrationTrustProfile)",
      "配置：\(configuration)",
      "能力：\(capabilities.isEmpty ? "无" : capabilities)",
    ].joined(separator: "\r\n")
    return AgentProviderItem(
      id: provider.providerID,
      rowText: "\(provider.displayName) · \(provider.providerID)",
      detailText: detail,
      requiresConfiguration: provider.requiresConfiguration
    )
  }

  public static func installation(
    _ installation: IPCAgentInstallationSummary,
    providerName: String? = nil
  ) -> AgentInstallationItem {
    let name = providerName ?? AgentProviderPresentation.displayName(installation.providerID)
    let state = availabilityLabel(installation.availability)
    let enabled = installation.isEnabled ? "已启用" : "已停用"
    let version = installation.version?.nilIfBlank ?? "未识别"
    let protocolRevision = installation.protocolRevision?.nilIfBlank ?? "未协商"
    var lines = [
      "Agent：\(installation.displayName)",
      "Provider：\(name)（\(installation.providerID)）",
      "ID：\(installation.installationID)",
      "状态：\(state)，\(enabled)",
      "可执行路径：\(installation.executablePath)",
      "版本：\(version)",
      "ACP 协议：\(protocolRevision)",
      "Adapter：r\(installation.adapterRevision)",
      "信任配置：\(installation.trustProfile)",
      "有效能力：\(installation.effectiveCapabilities.isEmpty ? "无" : installation.effectiveCapabilities.joined(separator: "、"))",
    ]
    if let error = installation.lastProbeError?.nilIfBlank {
      lines.append("Probe 错误：\(error)")
    }
    return AgentInstallationItem(
      id: installation.installationID,
      rowText: "\(installation.displayName) · \(state) · \(enabled)",
      detailText: lines.joined(separator: "\r\n"),
      isEnabled: installation.isEnabled,
      availability: installation.availability
    )
  }

  public static func permissionLabel(_ value: String) -> String {
    switch value {
    case "allowed": "允许"
    case "requiresLocalApproval": "需要本机批准"
    case "denied": "拒绝"
    default: "未知：\(value)"
    }
  }

  public static func availabilityLabel(_ value: String) -> String {
    switch value {
    case "available": "可用"
    case "needs_review": "需复核"
    case "unavailable": "不可用"
    default: "未知：\(value)"
    }
  }

  private static func capabilityNames(_ provider: IPCAgentProviderSummary) -> [String] {
    var values: [String] = []
    if provider.supportsModelSelection { values.append("模型") }
    if provider.supportsEffortSelection { values.append("推理强度") }
    if provider.supportsSessionContinuation { values.append("会话续接") }
    if provider.supportsSteer { values.append("Steer") }
    if provider.supportsWorkspaceWrite { values.append("工作区写入") }
    if provider.supportsSkillSelection { values.append("技能") }
    if provider.supportsSupervisor { values.append("Supervisor") }
    return values
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
