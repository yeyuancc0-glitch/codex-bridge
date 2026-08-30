import Foundation

package enum AgentToolCategory: String, Equatable, Sendable {
  case fileRead
  case fileSearch
  case fileList
  case fileWrite
  case command
  case webSearch
  case webFetch
  case subagent
  case reasoning
  case mcp
  case workflow
  case jobOutput
  case skill
  case other
}

package struct CodexTranscriptToolPresentation: Equatable, Sendable {
  package let title: String
  package let systemImage: String
}

package enum CodexTranscriptPresentation {
  package static func tool(
    providerID: String?,
    name: String?,
    status: String?
  ) -> CodexTranscriptToolPresentation {
    let category = category(providerID: providerID, name: name)
    let active = isActive(status)
    let title: String
    switch category {
    case .fileRead:
      title = active ? "正在读取文件" : "已读取文件"
    case .fileSearch:
      title = active ? "正在搜索文件" : "已搜索文件"
    case .fileList:
      title = active ? "正在列出文件" : "已列出文件"
    case .fileWrite:
      title = active ? "正在编辑文件" : "已编辑文件"
    case .command:
      title = active ? "正在运行命令" : "已运行命令"
    case .webSearch:
      title = active ? "正在搜索网页" : "已搜索网页"
    case .webFetch:
      title = active ? "正在读取网页" : "已读取网页"
    case .subagent:
      title = active ? "正在调用子代理" : "子代理已完成"
    case .reasoning:
      title = active ? "正在分析" : "分析完成"
    case .mcp:
      title = active ? "正在调用 MCP 工具" : "MCP 工具已完成"
    case .workflow:
      title = active ? "正在执行工作流" : "工作流已完成"
    case .jobOutput:
      title = active ? "正在读取后台任务输出" : "已读取后台任务输出"
    case .skill:
      title = active ? "正在执行技能" : "技能已完成"
    case .other:
      let provider = AgentProviderPresentation.displayName(providerID)
      let rawName = safeRawName(name)
      title =
        active
        ? "正在使用 \(provider) 工具：\(rawName)"
        : "已使用 \(provider) 工具：\(rawName)"
    }
    return CodexTranscriptToolPresentation(title: title, systemImage: systemImage(for: category))
  }

  package static func tool(
    name: String?,
    status: String?
  ) -> CodexTranscriptToolPresentation {
    tool(providerID: "codex", name: name, status: status)
  }

  package static func reasoningTitle(providerID: String?, streaming: Bool) -> String {
    let provider = AgentProviderPresentation.displayName(providerID)
    return streaming ? "\(provider) 正在分析" : "\(provider) 分析过程"
  }

  package static func statusLabel(_ status: String?) -> String {
    switch status?.lowercased() {
    case "completed": ""
    case "failed": "失败"
    case "declined": "已拒绝"
    case "cancelled": "已取消"
    case "pending": "等待执行"
    default: "进行中"
    }
  }

}
