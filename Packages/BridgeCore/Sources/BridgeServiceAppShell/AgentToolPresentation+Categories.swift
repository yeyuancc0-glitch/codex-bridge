extension CodexTranscriptPresentation {
  package static func category(providerID: String?, name: String?) -> AgentToolCategory {
    let values = normalizedValues(name)
    let tokens = Set(values.flatMap { $0.split(separator: "_").map(String.init) })

    // Network semantics must win over generic read/search words.
    if tokens.contains("web") || tokens.contains("browser") || tokens.contains("internet") {
      if tokens.contains("search") || tokens.contains("query") || tokens.contains("lookup") {
        return .webSearch
      }
      if tokens.contains("fetch") || tokens.contains("read") || tokens.contains("open")
        || tokens.contains("url") || tokens.contains("page") || tokens.contains("content")
      {
        return .webFetch
      }
    }
    if tokens.contains("url") && (tokens.contains("read") || tokens.contains("fetch")) {
      return .webFetch
    }

    let provider = normalize(providerID)
    switch provider {
    case "opencode":
      return openCodeCategory(values: values, tokens: tokens)
    case "deepseek-harness":
      return deepSeekCategory(values: values, tokens: tokens)
    case "antigravity":
      return antigravityCategory(values: values, tokens: tokens)
    case "codex":
      return codexCategory(values: values, tokens: tokens)
    default:
      return commonCategory(values: values, tokens: tokens)
    }
  }

  private static func codexCategory(values: [String], tokens: Set<String>) -> AgentToolCategory {
    if values.contains(where: { ["search_files", "file_search", "grep", "glob"].contains($0) }) {
      return .fileSearch
    }
    if values.contains(where: { ["read_files", "read_file", "file_read", "read"].contains($0) }) {
      return .fileRead
    }
    if values.contains(where: {
      ["list_files", "list_directory", "file_list", "list"].contains($0)
    }) {
      return .fileList
    }
    if values.contains(where: {
      ["file_change", "file_write", "patch", "edit", "write", "delete", "move"].contains($0)
    }) {
      return .fileWrite
    }
    if values.contains(where: {
      ["command_execution", "run_command", "execute", "exec", "bash", "shell"].contains($0)
    }) {
      return .command
    }
    return commonCategory(values: values, tokens: tokens)
  }

  private static func openCodeCategory(values: [String], tokens: Set<String>) -> AgentToolCategory {
    if values.contains(where: { ["websearch", "web_search", "search_web"].contains($0) }) {
      return .webSearch
    }
    if values.contains(where: { ["fetch", "webfetch", "web_fetch"].contains($0) }) {
      return .webFetch
    }
    if values == ["think"] || values.contains("think") && values.count == 1 {
      return .reasoning
    }
    if tokens.contains("task") || tokens.contains("agent") || tokens.contains("subagent")
      || tokens.contains("delegate") || tokens.contains("explore")
    {
      return .subagent
    }
    if values.contains(where: { ["read", "read_file", "file_read"].contains($0) }) {
      return .fileRead
    }
    if values.contains(where: { ["search", "grep", "glob", "find", "file_search"].contains($0) }) {
      return .fileSearch
    }
    if values.contains(where: { ["list", "list_files", "list_directory"].contains($0) }) {
      return .fileList
    }
    if values.contains(where: {
      ["edit", "write", "patch", "delete", "move", "file_change"].contains($0)
    }) {
      return .fileWrite
    }
    if values.contains(where: { ["execute", "command", "bash", "shell", "exec"].contains($0) }) {
      return .command
    }
    return commonCategory(values: values, tokens: tokens)
  }

  private static func deepSeekCategory(values: [String], tokens: Set<String>) -> AgentToolCategory {
    if values.contains(where: {
      ["web_search", "websearch", "search_web", "web_search_deepseek"].contains($0)
    }) {
      return .webSearch
    }
    if values.contains(where: {
      ["web_fetch", "webfetch", "fetch_web", "web_fetch_http", "read_url_content"].contains($0)
    }) {
      return .webFetch
    }
    if tokens.contains("subagent") || tokens.contains("delegate") || tokens.contains("fork") {
      return .subagent
    }
    if values.contains("job_output") {
      return .jobOutput
    }
    if values.contains(where: {
      ["bash", "shell", "run_command", "execute", "exec"].contains($0)
    }) {
      return .command
    }
    if tokens.contains("skill") {
      return .skill
    }
    if values.contains(where: {
      ["search", "fs_search", "tool_fs_search", "search_files", "grep", "glob"].contains($0)
    }) {
      return .fileSearch
    }
    if values.contains(where: { ["read", "read_file", "file_read", "tool_fs"].contains($0) }) {
      return .fileRead
    }
    if values.contains(where: {
      ["edit", "write", "patch", "delete", "move", "file_change"].contains($0)
    }) {
      return .fileWrite
    }
    return commonCategory(values: values, tokens: tokens)
  }

  private static func antigravityCategory(values: [String], tokens: Set<String>)
    -> AgentToolCategory
  {
    if values.contains(where: { ["search_web", "web_search"].contains($0) }) {
      return .webSearch
    }
    if values.contains(where: { ["read_url_content", "fetch_url", "url_fetch"].contains($0) }) {
      return .webFetch
    }
    if tokens.contains("subagent") || tokens.contains("delegate") {
      return .subagent
    }
    if tokens.contains("mcp") {
      return .mcp
    }
    if values.contains(where: { ["view_file", "read_file", "file_read"].contains($0) }) {
      return .fileRead
    }
    if values.contains(where: { ["search_files", "grep", "glob"].contains($0) }) {
      return .fileSearch
    }
    if values.contains(where: { ["list_files", "list_directory"].contains($0) }) {
      return .fileList
    }
    if values.contains(where: {
      ["run_command", "command", "execute", "exec", "bash", "shell"].contains($0)
    }) {
      return .command
    }
    return commonCategory(values: values, tokens: tokens)
  }

  private static func commonCategory(values: [String], tokens: Set<String>) -> AgentToolCategory {
    let fileContext = !tokens.isDisjoint(with: ["file", "files", "path", "project", "repository"])
    if fileContext,
      !tokens.isDisjoint(with: ["search", "find", "grep", "glob", "lookup"])
    {
      return .fileSearch
    }
    if fileContext, !tokens.isDisjoint(with: ["read", "view", "open"]) {
      return .fileRead
    }
    if fileContext, !tokens.isDisjoint(with: ["list", "enumerate"]) {
      return .fileList
    }
    if fileContext,
      !tokens.isDisjoint(with: ["write", "edit", "patch", "create", "delete", "move"])
    {
      return .fileWrite
    }
    if !tokens.isDisjoint(with: ["command", "execute", "exec", "bash", "shell", "terminal"]) {
      return .command
    }
    if tokens.contains("mcp") { return .mcp }
    if tokens.contains("subagent") || tokens.contains("delegate") { return .subagent }
    if tokens.contains("workflow") { return .workflow }
    if values.contains("job_output") { return .jobOutput }
    if tokens.contains("skill") { return .skill }
    if values.contains("think") { return .reasoning }
    if values.contains(where: { ["read_file", "file_read"].contains($0) }) { return .fileRead }
    if values.contains(where: { ["search_files", "file_search"].contains($0) }) {
      return .fileSearch
    }
    if values.contains(where: { ["run_command", "command_execution"].contains($0) }) {
      return .command
    }
    return .other
  }

  package static func systemImage(for category: AgentToolCategory) -> String {
    switch category {
    case .fileRead: "book"
    case .fileSearch: "magnifyingglass"
    case .fileList: "list.bullet"
    case .fileWrite: "pencil"
    case .command: "terminal"
    case .webSearch, .webFetch: "globe"
    case .subagent: "person.2"
    case .reasoning: "brain.head.profile"
    case .mcp: "network"
    case .workflow: "arrow.triangle.2.circlepath"
    case .jobOutput: "text.page"
    case .skill: "wand.and.stars"
    case .other: "wrench.and.screwdriver"
    }
  }

  package static func isActive(_ status: String?) -> Bool {
    switch status?.lowercased() {
    case "completed", "failed", "declined", "cancelled": false
    default: true
    }
  }

  private static func normalizedValues(_ value: String?) -> [String] {
    guard let value else { return [] }
    let normalized =
      value
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "_")
    return normalized.isEmpty ? [] : [normalized]
  }

  private static func normalize(_ value: String?) -> String {
    guard let value else { return "" }
    return value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
  }

  package static func safeRawName(_ value: String?) -> String {
    guard let value else { return "未知工具" }
    let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !normalized.isEmpty else { return "未知工具" }
    return normalized.count > 96 ? String(normalized.prefix(95)) + "…" : normalized
  }
}
