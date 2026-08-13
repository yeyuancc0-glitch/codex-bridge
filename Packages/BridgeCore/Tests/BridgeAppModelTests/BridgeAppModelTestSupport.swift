import BridgePresentation
import Foundation

@testable import BridgeAppModel

@MainActor
func waitUntil(
  _ condition: @MainActor () -> Bool
) async -> Bool {
  for _ in 0..<100 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

func firstTaskTitle(_ snapshot: BridgePresentationSnapshot) -> String? {
  guard case .ready(let page) = snapshot.tasks else { return nil }
  return page.tasks.first?.title
}

func snapshot(
  revision: UInt64,
  connection: BridgeAppConnectionState,
  taskTitle: String
) -> BridgeAppStateSnapshot {
  let row = TaskRowPresentation(
    id: "task-1",
    title: taskTitle,
    projectName: "Codex Bridge",
    threadLabel: "thread-1",
    status: .running,
    model: "gpt-5.6-codex",
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
  return BridgeAppStateSnapshot(
    revision: revision,
    connectionState: connection,
    presentation: BridgePresentationSnapshot(
      overview: .loading(message: "正在读取"),
      tasks: .ready(TaskPagePresentation(tasks: [row], details: [])),
      projects: .loading(message: "正在读取"),
      threads: .loading(message: "正在读取"),
      approvals: .loading(message: "正在读取"),
      connections: .loading(message: "正在读取"),
      logs: .loading(message: "正在读取"),
      settings: .loading(message: "正在读取")
    )
  )
}

func approvalSnapshot(
  capabilities: [BridgeApprovalCapability]
) -> BridgeAppStateSnapshot {
  let detail = approvalPresentation()
  let row = ApprovalRowPresentation(
    id: detail.id,
    source: detail.source,
    summary: detail.operationTitle,
    risk: .waiting,
    requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
  let presentation = BridgePresentationSnapshot(
    overview: .loading(message: "正在读取"),
    tasks: .loading(message: "正在读取"),
    projects: .loading(message: "正在读取"),
    threads: .loading(message: "正在读取"),
    approvals: .ready(ApprovalPagePresentation(pending: [row], details: [detail])),
    connections: .loading(message: "正在读取"),
    logs: .loading(message: "正在读取"),
    settings: .loading(message: "正在读取")
  )
  return BridgeAppStateSnapshot(
    revision: 1,
    connectionState: .ready,
    presentation: presentation,
    pendingSheet: .codexApproval(detail),
    approvalCapabilities: capabilities
  )
}

func approvalPresentation() -> CodexApprovalPresentation {
  CodexApprovalPresentation(
    id: "approval-1",
    taskID: "task-1",
    source: "Codex Execution",
    threadID: "thread-1",
    turnID: "turn-1",
    operationID: "operation-1",
    operationTitle: "运行只读 Git 检查",
    commandArguments: ["/usr/bin/git", "status", "--short"],
    workingDirectory: "/tmp/project",
    reason: "收集 Git 状态",
    supervisorRisk: "低风险，只读",
    consequences: ["读取仓库元数据"],
    canAllow: true
  )
}

func capability() -> BridgeApprovalCapability {
  BridgeApprovalCapability(
    approvalID: "approval-1",
    taskID: "task-1",
    threadID: "thread-1",
    turnID: "turn-1",
    operationID: "operation-1",
    authorizationHandle: "opaque-one-time-handle",
    allowOnceEligible: true
  )
}

func taskSubmission() -> BridgeAppTaskSubmission {
  BridgeAppTaskSubmission(
    requestID: "request-1",
    projectID: "project-1",
    goal: "完成 AppModel",
    acceptanceCriteria: ["测试通过"],
    model: "gpt-5.6-codex",
    effort: "high",
    permissionMode: "workspace-write",
    networkAllowed: false
  )
}
