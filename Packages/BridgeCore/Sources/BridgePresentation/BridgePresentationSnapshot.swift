import Foundation

public struct BridgePresentationSnapshot: Equatable, Sendable {
  public let overview: PresentationLoadState<OverviewPresentation>
  public let tasks: PresentationLoadState<TaskPagePresentation>
  public let projects: PresentationLoadState<ProjectPagePresentation>
  public let threads: PresentationLoadState<ThreadPagePresentation>
  public let approvals: PresentationLoadState<ApprovalPagePresentation>
  public let connections: PresentationLoadState<ConnectionPagePresentation>
  public let logs: PresentationLoadState<LogPagePresentation>
  public let settings: PresentationLoadState<SettingsPagePresentation>

  public init(
    overview: PresentationLoadState<OverviewPresentation>,
    tasks: PresentationLoadState<TaskPagePresentation>,
    projects: PresentationLoadState<ProjectPagePresentation>,
    threads: PresentationLoadState<ThreadPagePresentation>,
    approvals: PresentationLoadState<ApprovalPagePresentation>,
    connections: PresentationLoadState<ConnectionPagePresentation>,
    logs: PresentationLoadState<LogPagePresentation>,
    settings: PresentationLoadState<SettingsPagePresentation>
  ) {
    self.overview = overview
    self.tasks = tasks
    self.projects = projects
    self.threads = threads
    self.approvals = approvals
    self.connections = connections
    self.logs = logs
    self.settings = settings
  }

  public static var loading: Self {
    Self(
      overview: .loading(message: "正在读取连接与任务状态"),
      tasks: .loading(message: "正在读取任务"),
      projects: .loading(message: "正在读取项目白名单"),
      threads: .loading(message: "正在读取 Codex 线程"),
      approvals: .loading(message: "正在读取待审批请求"),
      connections: .loading(message: "正在检查连接链路"),
      logs: .loading(message: "正在读取诊断日志"),
      settings: .loading(message: "正在读取设置")
    )
  }
}
