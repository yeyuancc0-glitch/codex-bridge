import BridgeAppModel
import BridgeCoordinator
import BridgeDomain
import BridgePresentation
import BridgeProjects
import Foundation

struct DesktopPresentationProjection {
  static func snapshot(
    projects: [RegisteredProject],
    tasks: [(TaskProjection, [TaskEventEnvelope])],
    diagnostics: [LogEntryPresentation]
  ) -> BridgePresentationSnapshot {
    let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    let taskRows = tasks.map { taskRow($0.0, projects: projectsByID, events: $0.1) }
    let taskDetails = tasks.map { taskDetail($0.0, projects: projectsByID, events: $0.1) }
    let projectRows = projects.map(project)
    let approvals = tasks.flatMap { approvalRows($0.0, events: $0.1) }
    let active = taskRows.filter { row in
      row.status == .running || row.status == .waiting || row.status == .checking
    }
    let recent = taskRows.filter { row in !active.contains(where: { $0.id == row.id }) }
    let connectionNodes = connectionPath()
    return BridgePresentationSnapshot(
      overview: .ready(
        OverviewPresentation(
          connectionPath: connectionNodes,
          attentionItems: [
            AttentionItemPresentation(
              id: "connection-setup",
              title: "连接尚未配置",
              detail: "完成首次引导后，才能启动本地 MCP 与 Secure Tunnel。",
              status: .waiting,
              destination: .connections
            )
          ],
          activeTasks: active,
          recentTasks: recent,
          registeredProjectCount: projectRows.count,
          rateLimitSummary: "尚未读取 Codex 账号限额"
        )
      ),
      tasks: .ready(TaskPagePresentation(tasks: taskRows, details: taskDetails)),
      projects: .ready(ProjectPagePresentation(projects: projectRows)),
      threads: .ready(ThreadPagePresentation(threads: [])),
      approvals: .ready(ApprovalPagePresentation(pending: approvals)),
      connections: .ready(
        ConnectionPagePresentation(
          mode: "尚未配置",
          endpoint: "本地 MCP 尚未启动",
          nodes: connectionNodes,
          receivingPaused: false,
          canChangeReceiving: false,
          canTest: false
        )
      ),
      logs: .ready(
        LogPagePresentation(entries: diagnostics, isStreaming: true, canExport: false)
      ),
      settings: .ready(settings())
    )
  }

  static func failure(message: String) -> BridgePresentationSnapshot {
    let error = PresentationErrorState(title: "本机状态不可用", message: message)
    return BridgePresentationSnapshot(
      overview: .failed(error),
      tasks: .failed(error),
      projects: .failed(error),
      threads: .failed(error),
      approvals: .failed(error),
      connections: .failed(error),
      logs: .failed(error),
      settings: .failed(error)
    )
  }

  private static func project(_ value: RegisteredProject) -> ProjectPresentation {
    let available = (try? value.validateCurrentRoots()) != nil
    return ProjectPresentation(
      id: value.id.rawValue,
      name: value.name,
      normalizedPath: value.primaryRoot.canonicalPath,
      isDirty: false,
      canRead: value.accessPolicy.read == .allowed,
      canWrite: value.accessPolicy.write != .denied,
      networkAllowed: value.accessPolicy.network != .denied,
      requiresLocalConfirmation: value.accessPolicy.write == .requiresLocalApproval
        || value.accessPolicy.network == .requiresLocalApproval,
      verificationCommands: value.verificationCommands.map(command),
      threadCount: 0,
      isAvailable: available,
      threadCountIsKnown: false,
      gitFactsKnown: false,
      readPermission: permission(value.accessPolicy.read),
      writePermission: permission(value.accessPolicy.write),
      networkPermission: permission(value.accessPolicy.network)
    )
  }

  private static func permission(_ value: ProjectPermission) -> ProjectPermissionPresentation {
    switch value {
    case .allowed: .allowed
    case .requiresLocalApproval: .requiresLocalApproval
    default: .denied
    }
  }

  private static func command(_ value: VerificationCommand) -> String {
    ([value.executable] + value.arguments).joined(separator: " ")
  }

  private static func taskRow(
    _ projection: TaskProjection,
    projects: [ProjectID: RegisteredProject],
    events: [TaskEventEnvelope]
  ) -> TaskRowPresentation {
    let aggregate = projection.aggregate
    return TaskRowPresentation(
      id: aggregate.id.rawValue,
      title: bounded(aggregate.submission.contract.goal, maximumCharacters: 100),
      projectName: projects[aggregate.submission.projectID]?.name ?? "未知项目",
      threadLabel: aggregate.binding?.threadID.rawValue ?? "尚未绑定",
      status: status(aggregate.phase),
      model: aggregate.submission.execution.model,
      updatedAt: events.last?.createdAt ?? .distantPast
    )
  }

  private static func taskDetail(
    _ projection: TaskProjection,
    projects: [ProjectID: RegisteredProject],
    events: [TaskEventEnvelope]
  ) -> TaskDetailPresentation {
    let aggregate = projection.aggregate
    return TaskDetailPresentation(
      id: aggregate.id.rawValue,
      title: bounded(aggregate.submission.contract.goal, maximumCharacters: 100),
      goal: bounded(aggregate.submission.contract.goal, maximumCharacters: 4_096),
      projectName: projects[aggregate.submission.projectID]?.name ?? "未知项目",
      threadID: aggregate.binding?.threadID.rawValue ?? "尚未绑定",
      model: aggregate.submission.execution.model,
      effort: aggregate.submission.execution.effort,
      status: status(aggregate.phase),
      supervisorStatus: aggregate.submission.supervisor.enabled ? .waiting : .paused,
      startedAt: events.first(where: { $0.kind == "task.domain.turnStarted" })?.createdAt,
      plan: aggregate.submission.contract.requirements,
      currentStep: aggregate.phase.label,
      finalSummary: aggregate.reportReference == nil ? nil : "最终报告已存储",
      timeline: events.suffix(200).map(event),
      diagnosticSummary: aggregate.failureReason,
      canOpenInCodex: aggregate.binding != nil,
      canInterrupt: false
    )
  }

  private static func event(_ value: TaskEventEnvelope) -> TaskEvidenceEventPresentation {
    TaskEvidenceEventPresentation(
      id: "\(value.taskID.rawValue)-\(value.sequence)",
      source: value.source,
      kind: value.kind,
      detail: "事件序号 \(value.sequence)",
      status: value.severity == "error" ? .failed : .ready,
      occurredAt: value.createdAt
    )
  }

  private static func approvalRows(
    _ projection: TaskProjection,
    events: [TaskEventEnvelope]
  ) -> [ApprovalRowPresentation] {
    projection.aggregate.pendingApprovalIDs.sorted { $0.rawValue < $1.rawValue }.map { approval in
      ApprovalRowPresentation(
        id: approval.rawValue,
        source: "Codex Execution",
        summary: "等待不可变操作证据；当前不能批准",
        risk: .blocked,
        requestedAt: events.last?.createdAt ?? .distantPast
      )
    }
  }

  private static func connectionPath() -> [ConnectionNodePresentation] {
    [
      ConnectionNodePresentation(
        id: "app",
        title: "Codex Bridge",
        detail: "原生应用与本机持久化已启动",
        status: .ready
      ),
      ConnectionNodePresentation(
        id: "mcp",
        title: "本地 MCP",
        detail: "等待首次引导配置认证 Secret",
        status: .disconnected
      ),
      ConnectionNodePresentation(
        id: "tunnel",
        title: "Secure Tunnel",
        detail: "等待 Runtime Key 与 Tunnel ID",
        status: .disconnected
      ),
      ConnectionNodePresentation(
        id: "chatgpt",
        title: "ChatGPT",
        detail: "尚未连接",
        status: .disconnected
      ),
    ]
  }

  private static func settings() -> SettingsPagePresentation {
    SettingsPagePresentation(
      general: [
        SettingTogglePresentation(
          id: "launch-at-login",
          title: "登录时启动",
          detail: "将在系统集成阶段启用",
          isOn: false,
          isEnabled: false
        )
      ],
      notifications: [
        SettingTogglePresentation(
          id: "task-notifications",
          title: "任务通知",
          detail: "将在通知权限配置完成后启用",
          isOn: false,
          isEnabled: false
        )
      ],
      security: [
        SettingTogglePresentation(
          id: "remote-receiving",
          title: "接收远程任务",
          detail: "Tunnel 严格就绪前保持关闭",
          isOn: false,
          isEnabled: false
        )
      ],
      retentionSummary: "任务事件持久保存；支持包导出尚未启用"
    )
  }

  private static func status(_ phase: TaskPhase) -> PresentationStatus {
    switch phase {
    case .draft, .preparing, .recovering: .checking
    case .running: .running
    case .awaitingLocalApproval, .awaitingCodexApproval: .waiting
    case .suspended: .paused
    case .verifying: .checking
    case .unknown: .degraded
    case .completed: .completed
    case .failed: .failed
    case .interrupted, .rejected: .blocked
    }
  }

  private static func bounded(_ value: String, maximumCharacters: Int) -> String {
    value.count <= maximumCharacters ? value : String(value.prefix(maximumCharacters - 1)) + "…"
  }
}

extension TaskPhase {
  fileprivate var label: String {
    switch self {
    case .draft: "草稿"
    case .awaitingLocalApproval: "等待本机确认"
    case .preparing: "准备执行"
    case .running: "Codex 正在执行"
    case .awaitingCodexApproval: "等待 Codex 审批"
    case .suspended: "已暂停"
    case .verifying: "等待验证与报告"
    case .recovering: "正在恢复"
    case .unknown: "恢复状态待确认"
    case .completed: "已完成"
    case .failed: "失败"
    case .interrupted: "已中断"
    case .rejected: "已拒绝"
    }
  }
}
