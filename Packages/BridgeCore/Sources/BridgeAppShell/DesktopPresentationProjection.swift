import BridgeAppModel
import BridgeCoordinator
import BridgeDomain
import BridgePresentation
import BridgeProjects
import BridgeTunnel
import Foundation

struct DesktopPresentationProjection {
  static func snapshot(
    projects: [RegisteredProject],
    tasks: [(TaskProjection, [TaskEventEnvelope])],
    diagnostics: [LogEntryPresentation],
    connection: DesktopTransportHealth = .stopped
  ) -> BridgePresentationSnapshot {
    let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    let taskRows = tasks.map { taskRow($0.0, projects: projectsByID, events: $0.1) }
    let taskDetails = tasks.map { taskDetail($0.0, projects: projectsByID, events: $0.1) }
    let projectRows = projects.map(project)
    let approvals = tasks.flatMap { approvalRows($0.0, events: $0.1) }
    let approvalDetails = tasks.flatMap { approvalDetails($0.0) }
    let active = taskRows.filter { row in
      row.status == .running || row.status == .waiting || row.status == .checking
    }
    let recent = taskRows.filter { row in !active.contains(where: { $0.id == row.id }) }
    let connectionNodes = connectionPath(connection)
    let attentionItems: [AttentionItemPresentation] =
      connection.acceptsRemoteSubmissions
      ? []
      : [
        AttentionItemPresentation(
          id: "connection-setup",
          title: connection.localMCPURL == nil ? "连接尚未配置" : "远程连接尚未就绪",
          detail: connection.actionRequired
            ? "连接需要本机处理认证或配置错误。"
            : "本机能力保持可用；严格远程健康检查通过前不会接收 ChatGPT 任务。",
          status: connection.actionRequired ? .blocked : .waiting,
          destination: .connections
        )
      ]
    return BridgePresentationSnapshot(
      overview: .ready(
        OverviewPresentation(
          connectionPath: connectionNodes,
          attentionItems: attentionItems,
          activeTasks: active,
          recentTasks: recent,
          registeredProjectCount: projectRows.count,
          rateLimitSummary: "尚未读取 Codex 账号限额"
        )
      ),
      tasks: .ready(TaskPagePresentation(tasks: taskRows, details: taskDetails)),
      projects: .ready(ProjectPagePresentation(projects: projectRows)),
      threads: .ready(ThreadPagePresentation(threads: [])),
      approvals: .ready(
        ApprovalPagePresentation(
          pending: approvals,
          details: approvalDetails
        )
      ),
      connections: .ready(
        ConnectionPagePresentation(
          mode: connection.endpointDescription,
          endpoint: connection.localMCPURL.map(Self.publicLocalEndpoint) ?? "本地 MCP 尚未启动",
          nodes: connectionNodes,
          receivingPaused: false,
          canChangeReceiving: false,
          canTest: connection.localMCPURL != nil
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

  static func pendingSheet(
    projects: [RegisteredProject],
    tasks: [(TaskProjection, [TaskEventEnvelope])]
  ) -> PresentedBridgeSheet? {
    let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    if let task = tasks.first(where: { $0.0.aggregate.phase == .awaitingLocalApproval }) {
      return .taskConfirmation(
        taskConfirmation(task.0, projects: projectsByID)
      )
    }
    for task in tasks {
      if let approval = approvalDetails(task.0).first {
        return .codexApproval(approval)
      }
    }
    return nil
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
      verificationCommands: projects[aggregate.submission.projectID]?.verificationCommands.map(
        command
      ) ?? [],
      canAuthorizeVerification: canAuthorizeVerification(aggregate),
      diagnosticSummary: aggregate.failureReason,
      canOpenInCodex: aggregate.binding != nil,
      canInterrupt: aggregate.phase == .running || aggregate.phase == .awaitingCodexApproval
    )
  }

  private static func canAuthorizeVerification(_ aggregate: TaskAggregate) -> Bool {
    aggregate.binding != nil
      && (aggregate.phase == .running || aggregate.phase == .awaitingCodexApproval)
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
      let evidence = projection.aggregate.approvalEvidenceByID[approval]
      return ApprovalRowPresentation(
        id: approval.rawValue,
        source: "Codex Execution",
        summary: evidence?.operationTitle ?? "等待不可变操作证据；当前不能批准",
        risk: .blocked,
        requestedAt: events.last?.createdAt ?? .distantPast
      )
    }
  }

  private static func approvalDetails(
    _ projection: TaskProjection
  ) -> [CodexApprovalPresentation] {
    guard let binding = projection.aggregate.binding else { return [] }
    return projection.aggregate.pendingApprovalIDs.sorted { $0.rawValue < $1.rawValue }.map {
      approval in
      guard let evidence = projection.aggregate.approvalEvidenceByID[approval] else {
        return CodexApprovalPresentation(
          id: approval.rawValue,
          taskID: projection.aggregate.id.rawValue,
          source: "Codex Execution",
          threadID: binding.threadID.rawValue,
          turnID: binding.turnID.rawValue,
          operationTitle: "缺少权威操作证据",
          workingDirectory: "未展示：缺少权威 cwd 证据",
          reason: "Bridge 尚未收到可持久化的操作证据与影响范围。",
          supervisorRisk: "安全阻断：当前只能拒绝此请求。",
          consequences: ["允许操作保持关闭；拒绝会精确回复这一审批请求。"],
          canAllow: false
        )
      }
      var evidenceItems = evidence.displayArguments
      if let displayCommand = evidence.displayCommand {
        evidenceItems.insert("展示命令：\(displayCommand)", at: 0)
      }
      var consequences = ["证据摘要 SHA-256：\(evidence.evidenceDigest)"]
      if evidence.omittedOperationCount > 0 {
        consequences.append("另有 \(evidence.omittedOperationCount) 项操作未在摘要中展示。")
      }
      consequences.append("当前版本尚未完成确定性策略裁决，因此只能拒绝。")
      return CodexApprovalPresentation(
        id: approval.rawValue,
        taskID: projection.aggregate.id.rawValue,
        source: "Codex Execution",
        threadID: binding.threadID.rawValue,
        turnID: binding.turnID.rawValue,
        operationID: evidence.itemID,
        operationTitle: evidence.operationTitle,
        evidenceItems: evidenceItems,
        fileOperation: evidence.changedPaths.isEmpty
          ? nil : evidence.changedPaths.joined(separator: "、"),
        workingDirectory: evidence.workingDirectory ?? "未提供",
        reason: evidence.reason ?? "Codex 未提供原因。",
        supervisorRisk: evidence.authority == .correlatedDisplayOnly
          ? "命令字符串仅供展示，不具备 argv 权威性。"
          : "请求已与当前 Thread、Turn 和 Item 精确关联。",
        consequences: consequences,
        canAllow: false
      )
    }
  }

  private static func taskConfirmation(
    _ projection: TaskProjection,
    projects: [ProjectID: RegisteredProject]
  ) -> TaskConfirmationPresentation {
    let submission = projection.aggregate.submission
    var risks: [String] = []
    if submission.execution.permissionMode == "workspace-write" {
      risks.append("任务请求写入已注册工作区；开始后仍逐项执行策略与 Codex 审批。")
    }
    if submission.execution.networkAccess {
      risks.append("任务请求网络访问；本机策略与高风险硬拒绝仍然生效。")
    }
    risks.append("任务契约不可在确认时改写；如需只读模式，请重新提交新契约。")
    return TaskConfirmationPresentation(
      id: projection.aggregate.id.rawValue,
      goal: bounded(submission.contract.goal, maximumCharacters: 4_096),
      acceptanceCriteria: submission.contract.acceptanceCriteria.map {
        bounded($0, maximumCharacters: 4_096)
      },
      projectName: projects[submission.projectID]?.name ?? "未知项目",
      threadDescription: threadDescription(submission.thread),
      executionModel: submission.execution.model,
      effort: submission.execution.effort,
      permissionMode: submission.execution.permissionMode,
      networkAllowed: submission.execution.networkAccess,
      supervisorModel: "\(submission.supervisor.model) · \(submission.supervisor.effort)",
      estimatedReadScope: submission.contract.allowedPaths.isEmpty
        ? ["已注册项目根内；敏感路径与项目外路径仍会拒绝"]
        : submission.contract.allowedPaths,
      riskMessages: risks,
      availableModels: [submission.execution.model],
      availableEfforts: [submission.execution.effort],
      canRunReadOnly: false
    )
  }

  private static func threadDescription(_ target: ThreadTarget) -> String {
    switch target {
    case .new: "新 Thread（开始后创建）"
    case .existing(let threadID): threadID.rawValue
    }
  }

  private static func connectionPath(
    _ connection: DesktopTransportHealth
  ) -> [ConnectionNodePresentation] {
    let mcpReady = connection.localMCPURL != nil
    let remoteReady = connection.acceptsRemoteSubmissions
    return [
      ConnectionNodePresentation(
        id: "app",
        title: "Codex Bridge",
        detail: "原生应用与本机持久化已启动",
        status: .ready
      ),
      ConnectionNodePresentation(
        id: "mcp",
        title: "本地 MCP",
        detail: mcpReady ? "回环监听与受限工具目录已启动" : "等待首次引导配置认证 Secret",
        status: mcpReady ? .ready : .disconnected
      ),
      ConnectionNodePresentation(
        id: "tunnel",
        title: connection.endpointDescription,
        detail: connectionDetail(connection),
        status: presentationStatus(connection.lifecycle)
      ),
      ConnectionNodePresentation(
        id: "chatgpt",
        title: "ChatGPT",
        detail: remoteReady ? "严格远程健康检查已通过" : "远程提交保持关闭",
        status: remoteReady ? .ready : .disconnected
      ),
    ]
  }

  private static func presentationStatus(_ lifecycle: TunnelLifecycle) -> PresentationStatus {
    switch lifecycle {
    case .stopped: .disconnected
    case .starting, .authenticating, .connecting: .checking
    case .ready: .ready
    case .degraded: .degraded
    case .failed: .failed
    }
  }

  private static func connectionDetail(_ connection: DesktopTransportHealth) -> String {
    if connection.actionRequired { return "需要本机处理认证或配置错误" }
    return switch connection.lifecycle {
    case .stopped: "尚未启动"
    case .starting: "正在启动本地连接"
    case .authenticating: "正在验证传输凭证"
    case .connecting: "正在完成远程健康检查"
    case .ready:
      connection.acceptsRemoteSubmissions ? "远程传输已就绪" : "仅本机连接已就绪"
    case .degraded: "连接已降级，拒绝新的远程任务"
    case .failed: "连接失败"
    }
  }

  private static func publicLocalEndpoint(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "127.0.0.1"
    }
    if components.percentEncodedPath.hasPrefix("/mcp/") {
      let scheme = components.scheme ?? "http"
      let host = components.host ?? "127.0.0.1"
      let port = components.port.map { ":\($0)" } ?? ""
      return "\(scheme)://\(host)\(port)/mcp/<本机认证 Secret>"
    }
    return components.string ?? "127.0.0.1"
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
