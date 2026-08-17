import BridgeMCP
import Foundation

extension MCPServiceTaskSnapshot {
  var isTerminal: Bool {
    ["completed", "failed", "interrupted"].contains(status)
  }

  var isRunning: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(status)
  }
}

extension BridgeServiceRegistrationStatus {
  var localizedTitle: String {
    switch self {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}

public struct BridgeProjectPolicyDraft: Equatable, Sendable {
  public var readPermission: String
  public var writePermission: String
  public var networkPermission: String

  public init(project: MCPProjectSummary) {
    readPermission = project.capabilities.read
    writePermission = project.capabilities.write
    networkPermission = project.capabilities.network
  }
}
