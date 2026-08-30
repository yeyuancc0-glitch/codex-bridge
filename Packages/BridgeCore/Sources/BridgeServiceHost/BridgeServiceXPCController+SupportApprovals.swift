import BridgeCodexService
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import Foundation

extension BridgeServiceXPCController {
  static func approvalSummary(
    _ approval: ExecutionApprovalRequest
  ) -> IPCApprovalSummary {
    IPCApprovalSummary(
      approvalID: approval.id,
      taskID: approval.taskID.rawValue,
      threadID: approval.binding.threadID,
      turnID: approval.binding.turnID,
      itemID: approval.itemID,
      kind: approval.kind.rawValue,
      title: approval.title,
      summary: approval.summary,
      displayCommand: approval.displayCommand,
      relativePaths: approval.relativePaths,
      reason: approval.reason,
      decisionOptions: approval.availableDecisions.map(\.rawValue)
    )
  }

  static func taskStartApprovalSummary(
    _ approval: BridgeServiceApplication.PendingTaskStartApproval
  ) -> IPCApprovalSummary {
    let prompt = String(decoding: approval.prompt.utf8.prefix(4 * 1_024), as: UTF8.self)
    let clientLabel: String
    switch approval.clientID {
    case MCPClientID.chatGPT.rawValue:
      clientLabel = "ChatGPT"
    case MCPClientID.qwenStudio.rawValue:
      clientLabel = "Qwen"
    default:
      clientLabel = "远程客户端"
    }
    let permission = taskPermissionDescription(
      providerID: approval.providerID,
      permissionMode: approval.permissionMode
    )
    let network = taskNetworkDescription(
      providerID: approval.providerID,
      networkAccess: approval.networkAllowed
    )
    return IPCApprovalSummary(
      approvalID: approval.approvalID,
      taskID: approval.taskID,
      threadID: "",
      turnID: "",
      itemID: approval.taskID,
      kind: "task_start",
      title: "\(clientLabel)请求调用 \(approval.providerDisplayName)",
      summary: prompt,
      reason: "项目：\(approval.projectID) · 权限：\(permission) · 网络：\(network)",
      decisionOptions: ["allow", "deny"]
    )
  }

  private static func taskPermissionDescription(
    providerID: String,
    permissionMode: String?
  ) -> String {
    guard let permissionMode, !permissionMode.isEmpty else { return "未记录" }
    if providerID == "opencode" {
      switch permissionMode {
      case "workspace-write": return "OpenCode 原生 Build（工作区可写）"
      case "read-only": return "OpenCode 原生 Plan（只读）"
      default: return "OpenCode：\(permissionMode)"
      }
    }
    if providerID == "antigravity" {
      switch permissionMode {
      case "read-only": return "Antigravity + macOS 项目只读边界"
      default: return "Antigravity 不支持：\(permissionMode)"
      }
    }
    return permissionMode
  }

  private static func taskNetworkDescription(
    providerID: String,
    networkAccess: Bool?
  ) -> String {
    if providerID == "opencode" {
      return "OpenCode 原生 permissions（network_access 不覆盖）"
    }
    if providerID == "antigravity" {
      return "Antigravity 原生工具权限（network_access 不覆盖）"
    }
    guard let networkAccess else { return "未记录" }
    return networkAccess ? "已请求" : "未请求"
  }
}
