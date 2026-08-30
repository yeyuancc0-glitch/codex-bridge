import BridgeIPC
import Foundation

/// Platform-neutral approval rows and detail text for native desktop shells.
/// The values are display-only; decisions are sent through the service client.
public enum ApprovalPresentation {
  public enum Identifier: Hashable, Sendable {
    case task(String)
    case direct(String)

    public var stableKey: String {
      switch self {
      case .task(let approvalID): "task:\(approvalID)"
      case .direct(let approvalID): "direct:\(approvalID)"
      }
    }
  }

  public struct Item: Equatable, Sendable {
    public let id: Identifier
    public let rowText: String
    public let detailText: String
    public let allowDecisions: [String]

    public var isDirect: Bool {
      if case .direct = id { return true }
      return false
    }
  }

  public static func task(
    _ approval: IPCApprovalSummary,
    projectName: String? = nil
  ) -> Item {
    let project = projectName ?? approval.taskID
    return Item(
      id: .task(approval.approvalID),
      rowText: "安全审批 · \(compact(approval.title)) — \(project)",
      detailText: taskDetails(approval, projectName: project),
      allowDecisions: allowDecisions(for: approval)
    )
  }

  public static func direct(
    _ approval: IPCPendingDirectApproval,
    projectName: String? = nil
  ) -> Item {
    let project = projectName ?? approval.projectID
    return Item(
      id: .direct(approval.approvalID),
      rowText: "Direct 审批 · \(compact(approval.kind)) — \(project)",
      detailText: directDetails(approval, projectName: project),
      allowDecisions: ["allow"]
    )
  }

  public static func decisionLabel(_ decision: String) -> String {
    switch decision {
    case "allow": return "仅本次允许"
    case "allow_for_session": return "本次会话允许"
    case "allow_similar_commands": return "允许此类命令"
    case "deny": return "拒绝"
    default:
      let value = compact(decision)
      return value.isEmpty ? "未知决策" : "未知决策：\(value)"
    }
  }

  private static func allowDecisions(for approval: IPCApprovalSummary) -> [String] {
    let candidates = approval.decisionOptions ?? ["allow"]
    var decisions: [String] = []
    for decision in candidates where decision.lowercased() != "deny" && !decision.isEmpty {
      if !decisions.contains(decision) { decisions.append(decision) }
    }
    return decisions
  }

  private static func taskDetails(
    _ approval: IPCApprovalSummary,
    projectName: String
  ) -> String {
    var lines = [
      "类型：任务审批（\(approval.kind)）",
      "标题：\(approval.title)",
      "项目：\(projectName)",
      "任务：\(approval.taskID)",
      "摘要：\(approval.summary)",
    ]
    if let reason = nonEmpty(approval.reason) {
      lines.append("原因：\(reason)")
    }
    if let command = nonEmpty(approval.displayCommand) {
      lines.append("请求内容：\(command)")
    }
    if !approval.relativePaths.isEmpty {
      lines.append("目标路径：\(approval.relativePaths.joined(separator: "、"))")
    }
    lines.append("可用决策：\(allowDecisions(for: approval).map(decisionLabel).joined(separator: "、"))")
    return lines.joined(separator: "\r\n")
  }

  private static func directDetails(
    _ approval: IPCPendingDirectApproval,
    projectName: String
  ) -> String {
    [
      "类型：Direct 审批（\(approval.kind)）",
      "项目：\(projectName)",
      "审批 ID：\(approval.approvalID)",
      "创建时间：\(ISO8601DateFormatter().string(from: approval.createdAt))",
      "摘要：\(approval.summary)",
      "可用决策：仅本次允许、拒绝",
    ].joined(separator: "\r\n")
  }

  private static func compact(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
