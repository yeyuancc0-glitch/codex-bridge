import Foundation

enum AntigravityCLIHeadlessPolicy {
  static func prompt(_ prompt: String) -> String {
    prompt
  }

  static func permissionDeniedSummary(
    permissionMode: String?,
    deniedToolName: String?
  ) -> String {
    let mode = permissionMode ?? "unknown"
    let tool = safeToolName(deniedToolName)
    let prefix =
      "Antigravity could not run \(tool.map { "native tool '\($0)'" } ?? "a requested tool") in headless mode (permission_mode=\(mode)). The provider response was preserved, but the task is incomplete. "
    switch category(tool) {
    case .web:
      return prefix
        + "This operation is controlled by Antigravity's Internet Access Policy, separately from Tool Execution Policy. In Antigravity CLI settings, allow trusted internet access or add a narrow domain/URL allow-rule, then retry. Bridge does not silently change shared settings."
    case .shell where mode == "proceed-in-sandbox":
      return prefix
        + "The command was not eligible for sandbox auto-execution. Add a narrow command allow-rule or choose another native non-interactive policy you explicitly trust, then retry. Bridge preserves agy's native sandbox and does not silently change shared settings."
    case .shell:
      return prefix
        + "In Antigravity CLI settings, choose Tool Execution Policy 'proceed-in-sandbox' or add a narrow command allow-rule, then retry. Bridge preserves agy's native sandbox and does not silently change shared settings."
    case .mcp:
      return prefix
        + "Grant this MCP operation in Antigravity's native permission settings, then retry. Bridge does not silently change shared settings."
    case .unknown:
      return prefix
        + "Review Antigravity's native permission settings and add a narrow allow-rule for this operation, then retry. Bridge does not silently change shared settings."
    }
  }

  private enum ToolCategory {
    case web
    case shell
    case mcp
    case unknown
  }

  private static func category(_ toolName: String?) -> ToolCategory {
    guard let toolName else { return .unknown }
    if toolName.contains("web") || toolName.contains("url") || toolName.contains("fetch")
      || toolName.contains("browser")
    {
      return .web
    }
    if toolName.contains("command") || toolName.contains("shell")
      || toolName.contains("terminal") || toolName == "bash"
    {
      return .shell
    }
    return toolName.contains("mcp") ? .mcp : .unknown
  }

  private static func safeToolName(_ value: String?) -> String? {
    guard let value = value?.lowercased(), !value.isEmpty, value.utf8.count <= 128 else {
      return nil
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
    return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
  }
}
