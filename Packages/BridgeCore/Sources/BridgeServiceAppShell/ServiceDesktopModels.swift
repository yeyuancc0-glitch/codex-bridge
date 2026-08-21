import BridgeIPC
import BridgeMCP
import CryptoKit
import Foundation

extension MCPServiceTaskSnapshot {
  var isTerminal: Bool {
    ["completed", "failed", "interrupted"].contains(status)
  }

  var isRunning: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(status)
  }

  var sourceDisplayName: String {
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

struct CodexActivityPresentation: Equatable {
  let statusText: String
  let detailText: String?
  let isActive: Bool
  let showsBubble: Bool

  init(task: MCPServiceTaskSnapshot?, activity: TaskConversationModel.Activity) {
    guard let task else {
      statusText = "已连接本机 Codex 引擎"
      detailText = nil
      isActive = false
      showsBubble = false
      return
    }
    detailText = task.currentStep
    switch task.status {
    case "starting":
      statusText = "Codex 正在启动…"
      isActive = true
      showsBubble = true
    case "running":
      (statusText, showsBubble) = Self.runningPresentation(activity)
      isActive = true
    case "waiting_for_codex_approval":
      statusText = "等待本机批准 Codex 操作…"
      isActive = true
      showsBubble = true
    case "completed":
      statusText = "Codex 已完成"
      isActive = false
      showsBubble = false
    case "failed":
      statusText = "Codex 执行失败"
      isActive = false
      showsBubble = false
    case "interrupted":
      statusText = "Codex 已中断"
      isActive = false
      showsBubble = false
    case "unknown":
      statusText = "Codex 状态未知"
      isActive = false
      showsBubble = false
    default:
      statusText = "等待本机批准任务"
      isActive = false
      showsBubble = false
    }
  }

  private static func runningPresentation(
    _ activity: TaskConversationModel.Activity
  ) -> (String, Bool) {
    switch activity {
    case .executing(let tool):
      return (tool.map { "Codex 正在执行 \($0)…" } ?? "Codex 正在执行工具…", true)
    case .responding:
      return ("Codex 正在输出…", false)
    case .idle, .thinking:
      return ("Codex 正在思考…", true)
    }
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
