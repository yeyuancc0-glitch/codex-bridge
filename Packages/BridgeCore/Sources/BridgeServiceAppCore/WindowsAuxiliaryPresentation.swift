import BridgeMCP

public enum DirectWorkspacePresentation {
  private static let canonicalEffortOrder = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ]

  public struct CommandItem: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String

    public init(id: String, rowText: String, detailText: String) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
    }
  }

  public struct SkillItem: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String

    public init(id: String, rowText: String, detailText: String) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
    }
  }

  public static func command(_ draft: BridgeWorkspaceCommandDraft) -> CommandItem {
    let name = draft.name.nilIfBlank ?? draft.executable.nilIfBlank ?? "未命名命令"
    let executable = draft.executable.nilIfBlank ?? "未设置可执行文件"
    let arguments = draft.arguments.nilIfBlank ?? "无"
    let directory = draft.workingDirectory.nilIfBlank ?? "项目根目录"
    let network = draft.requiresNetwork ? "需要网络" : "不需要网络"
    let risk = draft.risk == "elevated" ? "高风险" : "普通"
    let detail = [
      "命令：\(name)",
      "可执行文件：\(executable)",
      "参数前缀：\(arguments)",
      "工作目录：\(directory)",
      "网络：\(network)",
      "风险：\(risk)",
    ].joined(separator: "\r\n")
    return CommandItem(
      id: draft.id,
      rowText: "\(name) · \(executable)",
      detailText: detail
    )
  }

  public static func skill(_ skill: MCPServiceSkill) -> SkillItem {
    let actionNames = skill.actions.map(\.name).joined(separator: "、")
    let actions = actionNames.isEmpty ? "无" : actionNames
    let detail = [
      "Skill：\(skill.name)",
      "范围：\(skill.scope.rawValue)",
      "描述：\(skill.description.nilIfBlank ?? "无")",
      "触发词：\(skill.triggers.isEmpty ? "无" : skill.triggers.joined(separator: "、"))",
      "动作：\(actions)",
      "References：\(skill.hasReferences ? "有" : "无")",
    ].joined(separator: "\r\n")
    return SkillItem(
      id: skill.id, rowText: "\(skill.name) · \(skill.scope.rawValue)", detailText: detail)
  }

  public static func modeLabel(_ mode: String) -> String {
    switch mode {
    case "denied": "禁止直接执行"
    case "safe": "安全模式"
    case "full": "完全模式"
    default: "未知：\(mode)"
    }
  }

  public static func effortLabel(_ effort: String) -> String {
    switch effort.lowercased() {
    case "": "Provider 默认"
    case "none": "无"
    case "minimal": "最低"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh", "extra_high": "极高"
    case "max": "最高"
    case "ultra": "Ultra"
    default: effort
    }
  }

  public static func effortValues(
    catalog: [String],
    selected: [String] = [],
    includesProviderDefault: Bool = false
  ) -> [String] {
    let unique = (catalog + selected).reduce(into: [String]()) { values, effort in
      guard !effort.isEmpty, !values.contains(effort) else { return }
      values.append(effort)
    }
    let canonical = canonicalEffortOrder.filter(unique.contains)
    let ordered = canonical + unique.filter { !canonical.contains($0) }
    return includesProviderDefault ? [""] + ordered : ordered
  }

  public static func accessModeLabel(_ mode: String) -> String {
    switch mode {
    case "request-approval": "请求批准"
    case "auto-review": "自动评审"
    case "full-access": "完全访问"
    default: "未知：\(mode)"
    }
  }
}

public enum TaskLogPresentation {
  public struct Item: Equatable, Sendable {
    public let id: String
    public let rowText: String
    public let detailText: String
    public let sequence: Int64

    public init(id: String, rowText: String, detailText: String, sequence: Int64) {
      self.id = id
      self.rowText = rowText
      self.detailText = detailText
      self.sequence = sequence
    }
  }

  public static func flatten(
    tasks: [MCPServiceTaskSnapshot],
    projectNames: [String: String]
  ) -> [Item] {
    tasks.flatMap { task in
      task.recentEvents.map { event in
        let project = projectNames[task.projectID] ?? task.projectID
        let kind = kindLabel(kind: event.kind, summary: event.summary)
        let detail = [
          "序号：#\(event.sequence)",
          "项目：\(project)",
          "任务：\(task.taskID)",
          "类型：\(kind)",
          "时间：\(event.occurredAt)",
          "摘要：\(event.summary)",
        ].joined(separator: "\r\n")
        return Item(
          id: "\(task.taskID)_\(event.sequence)",
          rowText: "#\(event.sequence) · \(project) · \(kind) · \(event.summary)",
          detailText: detail,
          sequence: event.sequence
        )
      }
    }
    .sorted { $0.sequence > $1.sequence }
  }

  private static func kindLabel(kind: String, summary: String) -> String {
    let value = "\(kind) \(summary)".lowercased()
    if value.contains("command") || value.contains("exec") || value.contains("run") {
      return "命令"
    }
    if value.contains("file") || value.contains("edit") || value.contains("write") {
      return "文件"
    }
    if value.contains("failed") || value.contains("error") {
      return "错误"
    }
    return "事件"
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
