import AppKit
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation
import SwiftUI
import WebKit

public enum BridgeServiceNavigation: String, CaseIterable, Identifiable, Sendable {
  case overview
  case workbench
  case projects
  case logs
  case connections
  case settings

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "概览"
    case .workbench: "工作台"
    case .projects: "项目"
    case .logs: "日志"
    case .connections: "连接"
    case .settings: "设置"
    }
  }

  var symbol: String {
    switch self {
    case .overview: "gauge.with.needle"
    case .workbench: "bubble.left.and.text.bubble.right.fill"
    case .projects: "folder.fill"
    case .logs: "list.dash.header.rectangle"
    case .connections: "point.3.connected.trianglepath.dotted"
    case .settings: "gearshape"
    }
  }
}

public enum BridgeServiceConnectionState: Equatable, Sendable {
  case idle
  case registering
  case connecting
  case connected
  case requiresApproval
  case unavailable

  var label: String {
    switch self {
    case .idle: "未连接"
    case .registering: "正在注册"
    case .connecting: "正在连接"
    case .connected: "已连接"
    case .requiresApproval: "等待系统批准"
    case .unavailable: "不可用"
    }
  }

  var title: String { label }

  var systemImage: String { symbol }

  var symbol: String {
    switch self {
    case .idle: "circle"
    case .registering, .connecting: "arrow.triangle.2.circlepath"
    case .connected: "checkmark.circle.fill"
    case .requiresApproval: "exclamationmark.triangle.fill"
    case .unavailable: "xmark.circle.fill"
    }
  }
}

public typealias BridgeServiceClientFactory =
  @MainActor @Sendable () -> any BridgeServiceClientProtocol

struct AgentModelCatalogScope: Equatable {
  let installationID: String?
  let projectID: String?
}

@MainActor
public final class BridgeServiceAppModel: ObservableObject {
  @Published public var selection: BridgeServiceNavigation? = .overview {
    didSet { updateChatBrowserVisibility() }
  }
  @Published public internal(set) var registrationStatus: BridgeServiceRegistrationStatus
  @Published public internal(set) var connectionState: BridgeServiceConnectionState = .idle
  @Published public internal(set) var serviceStatus: IPCServiceStatusResponse?
  @Published public internal(set) var projects: [MCPProjectSummary] = []
  @Published public internal(set) var projectDetails: [String: MCPProjectDetail] = [:]
  @Published public internal(set) var agentProviders: [IPCAgentProviderSummary] = []
  @Published public internal(set) var agentInstallations: [IPCAgentInstallationSummary] = []
  @Published public internal(set) var agentModelOptionsByProvider:
    [String: [IPCAgentModelSummary]] = [:]
  @Published public internal(set) var agentModelRefreshingProviders: Set<String> = []
  @Published public internal(set) var agentModelRefreshErrorsByProvider: [String: String] = [:]
  @Published public internal(set) var agentModelOptions: [IPCAgentModelSummary] = [] {
    didSet { agentModelOptionsByProvider["opencode"] = agentModelOptions }
  }
  @Published public internal(set) var agentModelDefaults: [String: IPCAgentModelDefaultResponse] =
    [:]
  @Published public internal(set) var agentModelHydratingProviders: Set<String> = []
  @Published public internal(set) var openCodeDefaultModel: String?
  @Published public internal(set) var openCodeDefaultPermissionMode = "build"
  @Published public internal(set) var openCodeDefaultEffort: String?
  @Published public internal(set) var isManagingAgents = false
  @Published public internal(set) var isRefreshingAgentModels = false
  @Published public internal(set) var agentModelRefreshError: String?
  @Published public internal(set) var tasks: [MCPServiceTaskSnapshot] = []
  @Published public internal(set) var approvals: [IPCApprovalSummary] = []
  @Published public internal(set) var directApprovals: [IPCPendingDirectApproval] = []
  @Published public internal(set) var resolvingApprovalKeys: Set<String> = []
  @Published public internal(set) var directApprovalMode = "require"
  @Published public internal(set) var taskStartApprovalMode = "require"
  @Published public internal(set) var mcpClients: [IPCMCPClientStatus] = []
  @Published public internal(set) var models: [MCPModelSummary] = []
  @Published public internal(set) var modelPreferences: IPCModelPreferences?
  @Published public internal(set) var customInstructions: String?
  @Published public internal(set) var isSavingCustomInstructions = false
  @Published public internal(set) var modelCatalogError: String?
  @Published public internal(set) var threads: [MCPThreadSummary] = []
  @Published public internal(set) var skills: [MCPServiceSkill] = []
  @Published public internal(set) var selectedThread: MCPThreadReadPage?
  @Published public internal(set) var selectedThreadID: String?
  @Published public internal(set) var selectedTaskID: String?
  @Published public internal(set) var selectedProjectID: String?
  @Published public internal(set) var workbenchPermissionMode = "workspace-write"
  @Published public var chatWebView: WKWebView? {
    didSet {
      if chatWebView != nil {
        updateChatBrowserVisibility()
      }
    }
  }
  @Published public internal(set) var chatBrowserReloadRequest: UInt64 = 0
  @Published public internal(set) var isRefreshing = false
  @Published public internal(set) var lastRefreshAt: Date?
  @Published public internal(set) var conversation: TaskConversationModel?
  @Published public var errorMessage: String?
  @Published public internal(set) var toast: ToastNotice?
  @Published public var isChatBrowserEnabled: Bool {
    didSet {
      userDefaults.set(isChatBrowserEnabled, forKey: Self.chatBrowserEnabledKey)
      if isChatBrowserEnabled {
        updateChatBrowserVisibility()
      } else {
        cancelChatBrowserSleep()
        releaseChatWebView()
      }
    }
  }
  @Published public var keepServiceRunningAfterAppExit: Bool {
    didSet {
      userDefaults.set(
        keepServiceRunningAfterAppExit,
        forKey: Self.keepServiceRunningAfterAppExitKey
      )
    }
  }

  let registration: any BridgeServiceRegistrationManaging
  let clientFactory: BridgeServiceClientFactory
  let userDefaults: UserDefaults
  let pollInterval: Duration?
  let connectionRetryDelay: Duration
  let maximumConnectionAttempts: Int
  let chatBrowserSleepDelay: Duration
  let threadCatalogRefreshInterval: TimeInterval = 60
  let idlePollInterval: Duration = .seconds(10)
  var client: (any BridgeServiceClientProtocol)?
  var conversationPresentationCache = TaskConversationPresentationCache()
  var pollingTask: Task<Void, Never>?
  var refreshInProgress = false
  var pendingRefresh = false
  var pendingVisibleRefresh = false
  var pendingCatalogRefresh = false
  var chatWebViewSleepTask: Task<Void, Never>?
  var toastDismissTask: Task<Void, Never>?
  var workbenchProjectSyncTask: Task<Void, Never>?
  var workbenchPermissionModeSyncTask: Task<Void, Never>?
  var workbenchPermissionModeSyncGeneration: UInt64 = 0
  var confirmedWorkbenchPermissionMode = "workspace-write"
  var agentModelCatalogGenerations: [String: UInt64] = [:]
  var agentModelCatalogScopes: [String: AgentModelCatalogScope] = [:]
  var agentModelHydrationGenerations: [String: UInt64] = [:]
  var agentModelRefreshGenerations: [String: UInt64] = [:]
  var agentModelHydrationSuppressions: [String: AgentModelHydrationID] = [:]
  var agentModelDefaultLoadGenerations: [String: UInt64] = [:]
  var agentModelDefaultRevisions: [String: UInt64] = [:]
  var agentModelDefaultMutationTasks: [String: Task<Void, Never>] = [:]
  var resolvedTaskApprovalKeys: Set<String> = []
  var resolvedDirectApprovalKeys: Set<String> = []
  var chatBrowserResumeURL = URL(string: "https://chatgpt.com")!
  var lastThreadCatalogRefreshAt: Date?
  var started = false
  var stopped = false

  private static let chatBrowserEnabledKey = "chatBrowserEnabled"
  private static let keepServiceRunningAfterAppExitKey =
    "keepServiceRunningAfterAppExit"

  public convenience init() {
    self.init(
      registration: SystemBridgeServiceRegistration(),
      clientFactory: { BridgeServiceClient() }
    )
  }

  public init(
    registration: any BridgeServiceRegistrationManaging,
    clientFactory: @escaping BridgeServiceClientFactory,
    pollInterval: Duration? = .seconds(2),
    connectionRetryDelay: Duration = .milliseconds(200),
    maximumConnectionAttempts: Int = 20,
    chatBrowserSleepDelay: Duration = .seconds(180),
    userDefaults: UserDefaults = .standard
  ) {
    precondition(maximumConnectionAttempts > 0)
    self.registration = registration
    self.clientFactory = clientFactory
    self.pollInterval = pollInterval
    self.connectionRetryDelay = connectionRetryDelay
    self.maximumConnectionAttempts = maximumConnectionAttempts
    self.chatBrowserSleepDelay = chatBrowserSleepDelay
    self.userDefaults = userDefaults
    registrationStatus = registration.status
    isChatBrowserEnabled =
      userDefaults.object(forKey: Self.chatBrowserEnabledKey)
      as? Bool ?? true
    keepServiceRunningAfterAppExit =
      userDefaults.object(forKey: Self.keepServiceRunningAfterAppExitKey)
      as? Bool ?? true
  }

  deinit {
    pollingTask?.cancel()
    chatWebViewSleepTask?.cancel()
    toastDismissTask?.cancel()
    workbenchProjectSyncTask?.cancel()
    workbenchPermissionModeSyncTask?.cancel()
    for task in agentModelDefaultMutationTasks.values {
      task.cancel()
    }
  }

  public func projectName(for projectID: String) -> String {
    projects.first(where: { $0.projectID == projectID })?.name ?? projectID
  }

  public var runningTaskCount: Int {
    tasks.lazy.filter(\.isRunning).count
  }

  public var navigation: BridgeServiceNavigation {
    get { selection ?? .overview }
    set { selection = newValue }
  }

  func agentModelDefault(for providerID: String) -> IPCAgentModelDefaultResponse {
    agentModelDefaults[providerID]
      ?? IPCAgentModelDefaultResponse(
        providerID: providerID,
        model: providerID == "opencode" ? openCodeDefaultModel : nil,
        permissionMode:
          providerID == "opencode" ? openCodeDefaultPermissionMode : "workspace-write",
        effort: providerID == "opencode" ? openCodeDefaultEffort : nil
      )
  }

  func agentModelOptions(for providerID: String) -> [IPCAgentModelSummary] {
    agentModelOptionsByProvider[providerID]
      ?? (providerID == "opencode" ? agentModelOptions : [])
  }

  func agentSelectedModel(for providerID: String) -> IPCAgentModelSummary? {
    let options = agentModelOptions(for: providerID)
    if let modelID = agentModelDefault(for: providerID).model {
      return options.first(where: { $0.modelID == modelID })
    }
    return options.first(where: { !$0.supportedReasoningEfforts.isEmpty }) ?? options.first
  }

  func isRefreshingAgentModels(for providerID: String) -> Bool {
    agentModelRefreshingProviders.contains(providerID)
      || agentModelHydratingProviders.contains(providerID)
  }

  func agentModelRefreshError(for providerID: String) -> String? {
    agentModelRefreshErrorsByProvider[providerID]
  }

  public var exposureMode: MCPServiceExposureMode {
    serviceStatus?.exposureMode ?? .readOnly
  }

  public var safeLocalMCPDescription: String? {
    guard let raw = serviceStatus?.localMCPURL,
      let components = URLComponents(string: raw),
      let host = components.host
    else { return nil }
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(components.scheme ?? "http")://\(host)\(port)/mcp"
  }

  public func start() {
    Task { [weak self] in
      await self?.startAsync()
    }
  }

  public func stopClient() {
    Task { [weak self] in
      await self?.shutdownUI()
    }
  }

  public func registerService() {
    Task { [weak self] in
      await self?.enableBackgroundService()
    }
  }

  public func unregisterService() {
    Task { [weak self] in
      await self?.disableBackgroundService()
    }
  }

  public func openSystemSettings() {
    registration.openSystemSettings()
  }

  public func refresh() {
    Task { [weak self] in
      await self?.refresh(silent: false, includeCatalog: true)
    }
  }

  public func postToast(
    _ message: String,
    symbol: String = "checkmark.circle.fill",
    tone: StatusTone = .success
  ) {
    toastDismissTask?.cancel()
    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
      toast = ToastNotice(message: message, symbol: symbol, tone: tone)
    }
    toastDismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.25)) {
        self?.toast = nil
      }
    }
  }

  public func clearToast() {
    toastDismissTask?.cancel()
    withAnimation(.easeInOut(duration: 0.2)) {
      toast = nil
    }
  }
}

struct AgentModelHydrationID: Equatable {
  let providerID: String
  let installationID: String?
  let projectID: String?
  let modelID: String?

  init(
    providerID: String = "opencode",
    installationID: String?,
    projectID: String?,
    modelID: String?
  ) {
    self.providerID = providerID
    self.installationID = installationID
    self.projectID = projectID
    self.modelID = modelID
  }
}

public struct ToastNotice: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let message: String
  public let symbol: String
  public let tone: StatusTone

  public init(
    id: UUID = UUID(),
    message: String,
    symbol: String = "checkmark.circle.fill",
    tone: StatusTone = .success
  ) {
    self.id = id
    self.message = message
    self.symbol = symbol
    self.tone = tone
  }
}
