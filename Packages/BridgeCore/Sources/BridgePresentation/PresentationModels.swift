import Foundation

public enum BridgeNavigationDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case overview
  case tasks
  case projects
  case threads
  case approvals
  case connections
  case logs
  case settings

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "概览"
    case .tasks: "任务"
    case .projects: "项目"
    case .threads: "线程"
    case .approvals: "审批"
    case .connections: "连接"
    case .logs: "日志"
    case .settings: "设置"
    }
  }

  public var systemImage: String {
    switch self {
    case .overview: "rectangle.3.group"
    case .tasks: "checklist"
    case .projects: "folder"
    case .threads: "text.bubble"
    case .approvals: "hand.raised"
    case .connections: "point.3.connected.trianglepath.dotted"
    case .logs: "doc.text.magnifyingglass"
    case .settings: "gearshape"
    }
  }
}

public struct PresentationEmptyState: Equatable, Sendable {
  public let title: String
  public let message: String
  public let systemImage: String

  public init(title: String, message: String, systemImage: String) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
  }
}

public struct PresentationErrorState: Equatable, Sendable {
  public let title: String
  public let message: String
  public let recoveryActionTitle: String

  public init(title: String, message: String, recoveryActionTitle: String = "重试") {
    self.title = title
    self.message = message
    self.recoveryActionTitle = recoveryActionTitle
  }
}

public enum PresentationLoadState<Value: Equatable & Sendable>: Equatable, Sendable {
  case loading(message: String)
  case empty(PresentationEmptyState)
  case failed(PresentationErrorState)
  case ready(Value)
}

public enum PresentationStatus: String, Codable, Equatable, Hashable, Sendable {
  case checking
  case ready
  case running
  case waiting
  case degraded
  case disconnected
  case paused
  case blocked
  case failed
  case completed

  public var label: String {
    switch self {
    case .checking: "正在检查"
    case .ready: "正常"
    case .running: "运行中"
    case .waiting: "等待处理"
    case .degraded: "部分能力降级"
    case .disconnected: "已断开"
    case .paused: "已暂停"
    case .blocked: "已阻止"
    case .failed: "失败"
    case .completed: "已完成"
    }
  }

  public var systemImage: String {
    switch self {
    case .checking: "arrow.triangle.2.circlepath"
    case .ready, .completed: "checkmark.circle.fill"
    case .running: "play.circle.fill"
    case .waiting, .degraded: "exclamationmark.triangle.fill"
    case .disconnected: "bolt.slash.fill"
    case .paused: "pause.circle.fill"
    case .blocked: "hand.raised.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  public var accessibilitySummary: String {
    "状态：\(label)"
  }
}

public struct PresentationTimestamp: Codable, Equatable, Sendable {
  public let value: Date
  public let source: String

  public init(value: Date, source: String) {
    self.value = value
    self.source = source
  }
}

public enum PresentationTaskDecision: String, Equatable, Sendable {
  case start
  case reject
  case runReadOnly
}

public enum PresentationApprovalDecision: String, Equatable, Sendable {
  case allowOnce
  case deny
}

public enum PresentationAction: Equatable, Sendable {
  case refresh(BridgeNavigationDestination)
  case addProject
  case openProject(String)
  case reconnectProject(String)
  case removeProject(String)
  case updateProjectAccessPolicy(
    projectID: String,
    read: ProjectPermissionPresentation,
    write: ProjectPermissionPresentation,
    network: ProjectPermissionPresentation
  )
  case selectThreadProject(String)
  case loadMoreThreads
  case readThreadHistory(String)
  case readBoundThreadHistory(projectID: String, threadID: String)
  case loadMoreThreadHistory
  case continueThread(String)
  case createTaskFromThread(String)
  case copyThreadID(String)
  case archiveSupervisorThread(String)
  case openThreadInCodex(String)
  case openBoundThreadInCodex(projectID: String, threadID: String)
  case openTaskInCodex(String)
  case loadTaskEvidence(String)
  case prepareReadOnlyTask(projectID: String?, threadID: String?)
  case dismissReadOnlyTask
  case submitReadOnlyTask(ReadOnlyTaskDraftPresentation)
  case interruptTask(String)
  case suspendAmbiguousTask(String)
  case authorizeTaskVerification(String)
  case testConnection
  case setReceivingPaused(Bool)
  case exportSupportBundle
  case updateSetting(key: String, enabled: Bool)
  case decideTask(
    requestID: String,
    decision: PresentationTaskDecision,
    model: String,
    effort: String
  )
  case decideApproval(approvalID: String, decision: PresentationApprovalDecision)
  case decideBoundApproval(
    approvalID: String,
    taskID: String?,
    threadID: String,
    turnID: String,
    decision: PresentationApprovalDecision
  )
}

public protocol BridgePresentationActionHandling: Sendable {
  func handle(_ action: PresentationAction) async throws
}
