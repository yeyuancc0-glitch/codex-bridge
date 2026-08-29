import BridgeIPC
import BridgeMCP
import Crypto
import Foundation

extension MCPServiceTaskSnapshot {
  public var isTerminal: Bool {
    ["completed", "failed", "interrupted"].contains(status)
  }

  public var isRunning: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(status)
  }

  public var isActive: Bool {
    isRunning || status == "awaiting_local_approval"
  }

  public var providerIdentifier: String {
    AgentProviderPresentation.identifier(providerID)
  }

  public var providerDisplayName: String {
    AgentProviderPresentation.displayName(providerID)
  }

  public var providerSystemImage: String {
    AgentProviderPresentation.systemImage(providerID)
  }

  public var isCodexTask: Bool {
    providerIdentifier == "codex"
  }

  public var isExternalAgentTask: Bool {
    !isCodexTask
  }

  public var expectedControlID: String? {
    guard status == "running" else { return nil }
    return isCodexTask ? turnID : providerRunID
  }

  public var workbenchTitle: String {
    for value in [currentStep, resultSummary] {
      if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return "\(providerDisplayName) 任务"
  }

  public var failureDescription: String? {
    let code = failureCode?.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch (code, summary) {
    case (let code?, let summary?) where !code.isEmpty && !summary.isEmpty:
      return "\(code)：\(summary)"
    case (let code?, _) where !code.isEmpty:
      return code
    case (_, let summary?) where !summary.isEmpty && status == "failed":
      return summary
    default:
      return nil
    }
  }

  public var sourceDisplayName: String {
    if source == "chatgpt.mcp" || sourceClientID == MCPClientID.chatGPT.rawValue {
      return "ChatGPT"
    }
    if sourceClientID == MCPClientID.qwenStudio.rawValue {
      return "Qwen Studio"
    }
    if let sourceClientID, !sourceClientID.isEmpty {
      return sourceClientID
    }
    return source == "macos.app" ? "本机 App" : "本机任务"
  }
}

public enum AgentProviderPresentation {
  public static func identifier(_ providerID: String?) -> String {
    guard let providerID else { return "codex" }
    let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? "codex" : normalized
  }

  public static func displayName(_ providerID: String?) -> String {
    guard let providerID else { return "Codex" }
    switch identifier(providerID) {
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "deepseek-harness": return "DeepSeek Harness"
    case "antigravity": return "Antigravity"
    default:
      let value = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? "Codex" : value
    }
  }

  public static func systemImage(_ providerID: String?) -> String {
    switch identifier(providerID) {
    case "codex": return "cpu.fill"
    case "opencode": return "chevron.left.forwardslash.chevron.right"
    case "deepseek-harness": return "gearshape.2.fill"
    case "antigravity": return "sparkles"
    default: return "point.3.connected.trianglepath.dotted"
    }
  }
}

extension IPCAgentInstallationSummary {
  public var supportsEffortSelection: Bool {
    effectiveCapabilities.contains("selection.effort")
  }
}


public enum WorkbenchApprovalResolutionKey {
  public static func task(_ approvalID: String) -> String {
    "codex:\(approvalID)"
  }

  public static func direct(_ approvalID: String) -> String {
    "direct:\(approvalID)"
  }
}

public struct CodexActivityPresentation: Equatable {
  public let statusText: String
  public let detailText: String?
  public let isActive: Bool
  public let showsBubble: Bool

  public init(task: MCPServiceTaskSnapshot?, activity: TaskConversationModel.Activity) {
    guard let task else {
      statusText = "已连接本机 Codex 引擎"
      detailText = nil
      isActive = false
      showsBubble = false
      return
    }
    let providerName = task.providerDisplayName
    detailText = task.currentStep
    switch task.status {
    case "starting":
      statusText = "\(providerName) 正在启动…"
      isActive = true
      showsBubble = true
    case "running":
      (statusText, showsBubble) = Self.runningPresentation(
        activity,
        providerID: task.providerIdentifier,
        providerName: providerName
      )
      isActive = true
    case "awaiting_local_approval":
      statusText = "等待本机批准 \(providerName) 任务…"
      isActive = true
      showsBubble = true
    case "waiting_for_codex_approval":
      statusText = "等待本机批准 \(providerName) 操作…"
      isActive = true
      showsBubble = true
    case "completed":
      statusText = "\(providerName) 已完成"
      isActive = false
      showsBubble = false
    case "failed":
      statusText = "\(providerName) 执行失败"
      isActive = false
      showsBubble = false
    case "interrupted":
      statusText = "\(providerName) 已中断"
      isActive = false
      showsBubble = false
    case "unknown":
      statusText = "\(providerName) 状态未知"
      isActive = false
      showsBubble = false
    default:
      statusText = "等待本机批准 \(providerName) 任务"
      isActive = false
      showsBubble = false
    }
  }

  private static func runningPresentation(
    _ activity: TaskConversationModel.Activity,
    providerID: String,
    providerName: String
  ) -> (String, Bool) {
    switch activity {
    case .executing(let tool):
      guard let tool, !tool.isEmpty else {
        return ("\(providerName) 正在处理任务…", true)
      }
      let presentation = CodexTranscriptPresentation.tool(
        providerID: providerID,
        name: tool,
        status: "inProgress"
      )
      if CodexTranscriptPresentation.category(providerID: providerID, name: tool) == .other {
        return ("\(presentation.title)…", true)
      }
      return ("\(providerName) \(presentation.title)…", true)
    case .responding:
      return ("\(providerName) 正在输出…", false)
    case .thinking:
      return ("\(providerName) 正在分析…", true)
    case .idle:
      return ("\(providerName) 正在处理任务…", true)
    }
  }
}

extension BridgeServiceRegistrationStatus {
  public var localizedTitle: String {
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

  public init(
    readPermission: String = "allowed",
    writePermission: String = "requiresLocalApproval",
    networkPermission: String = "denied"
  ) {
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
  }

  public init(project: MCPProjectSummary) {
    readPermission = project.capabilities.read
    writePermission = project.capabilities.write
    networkPermission = project.capabilities.network
  }
}

public struct BridgeWorkspaceCommandDraft: Equatable, Identifiable, Sendable {
  public var name: String
  public var executable: String
  public var arguments: String
  public var workingDirectory: String
  public var requiresNetwork: Bool
  public var risk: String

  public var id: String {
    BridgeWorkspaceCommandDraft.stableID(
      name: name,
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory
    )
  }

  public init(
    name: String = "",
    executable: String = "",
    arguments: String = "",
    workingDirectory: String = "",
    requiresNetwork: Bool = false,
    risk: String = "normal"
  ) {
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }

  public init(command: MCPProjectCommand) {
    name = command.name
    executable = command.executable
    arguments = command.arguments.joined(separator: "\n")
    workingDirectory = command.workingDirectory ?? ""
    requiresNetwork = command.requiresNetwork
    risk = command.risk
  }

  public static func stableID(
    name: String,
    executable: String,
    arguments: String,
    workingDirectory: String
  ) -> String {
    let canonical = [
      name.trimmingCharacters(in: .whitespacesAndNewlines),
      executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments.split(separator: "\n").joined(separator: "\u{0}"),
      workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
    ].joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "wcmd_" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
  }

  public func toIPCCommand() -> IPCWorkspaceCommand {
    IPCWorkspaceCommand(
      commandID: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments: arguments.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
      workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty ? nil : workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
      requiresNetwork: requiresNetwork,
      risk: risk
    )
  }
}

public struct BridgeBlacklistDraft: Equatable, Identifiable, Sendable {
  public var executable: String
  public var pattern: String

  public var id: String {
    BridgeBlacklistDraft.stableID(executable: executable, pattern: pattern)
  }

  public init(executable: String = "", pattern: String = "") {
    self.executable = executable
    self.pattern = pattern
  }

  public init(rule: MCPCommandBlacklistRule) {
    executable = rule.executable ?? ""
    pattern = rule.pattern ?? ""
  }

  public static func stableID(executable: String, pattern: String) -> String {
    let canonical = [
      executable.trimmingCharacters(in: .whitespacesAndNewlines),
      pattern.trimmingCharacters(in: .whitespacesAndNewlines),
    ].joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "blk_" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
  }

  public func toIPCRule() -> IPCBlacklistRule {
    let executableValue = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    let patternValue = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    return IPCBlacklistRule(
      ruleID: id,
      executable: executableValue.isEmpty ? nil : executableValue,
      pattern: patternValue.isEmpty ? nil : patternValue
    )
  }
}

public struct ProjectWorkspaceDraftState: Equatable, Sendable {
  public let commandMode: String
  public let commands: [BridgeWorkspaceCommandDraft]
  public let commandBlacklist: [BridgeBlacklistDraft]

  public init(workspace: MCPDirectWorkspace) {
    commandMode = workspace.commandMode
    commands = workspace.commands.map(BridgeWorkspaceCommandDraft.init)
    commandBlacklist = workspace.commandBlacklist.map(BridgeBlacklistDraft.init)
  }

  public init(
    commandMode: String,
    commands: [BridgeWorkspaceCommandDraft],
    commandBlacklist: [BridgeBlacklistDraft]
  ) {
    self.commandMode = commandMode
    self.commands = commands.map { draft in
      let command = draft.toIPCCommand()
      return BridgeWorkspaceCommandDraft(
        name: command.name,
        executable: command.executable,
        arguments: command.arguments.joined(separator: "\n"),
        workingDirectory: command.workingDirectory ?? "",
        requiresNetwork: command.requiresNetwork,
        risk: command.risk
      )
    }
    self.commandBlacklist = commandBlacklist.map { draft in
      let rule = draft.toIPCRule()
      return BridgeBlacklistDraft(
        executable: rule.executable ?? "",
        pattern: rule.pattern ?? ""
      )
    }
  }
}

public enum BridgeServiceRegistrationStatus: String, CaseIterable, Sendable {
  case notRegistered = "not_registered"
  case enabled
  case requiresApproval = "requires_approval"
  case notFound = "not_found"
}
