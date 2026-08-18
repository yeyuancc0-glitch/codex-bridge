import AppKit
import BridgeIPC
import BridgeMCP
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

@MainActor
public final class BridgeServiceAppModel: ObservableObject {
  @Published public var selection: BridgeServiceNavigation? = .overview
  @Published public internal(set) var registrationStatus: BridgeServiceRegistrationStatus
  @Published public internal(set) var connectionState: BridgeServiceConnectionState = .idle
  @Published public internal(set) var serviceStatus: IPCServiceStatusResponse?
  @Published public internal(set) var projects: [MCPProjectSummary] = []
  @Published public internal(set) var tasks: [MCPServiceTaskSnapshot] = []
  @Published public internal(set) var approvals: [IPCApprovalSummary] = []
  @Published public internal(set) var models: [MCPModelSummary] = []
  @Published public internal(set) var modelPreferences: IPCModelPreferences?
  @Published public internal(set) var modelCatalogError: String?
  @Published public internal(set) var threads: [MCPThreadSummary] = []
  @Published public internal(set) var selectedThread: MCPThreadReadPage?
  @Published public internal(set) var selectedThreadID: String?
  @Published public internal(set) var selectedProjectID: String?
  @Published public var chatWebView: WKWebView?
  @Published public internal(set) var isRefreshing = false
  @Published public internal(set) var lastRefreshAt: Date?
  @Published public internal(set) var conversation: TaskConversationModel?
  @Published public var errorMessage: String?
  @Published public var isChatBrowserEnabled: Bool {
    didSet {
      UserDefaults.standard.set(isChatBrowserEnabled, forKey: Self.chatBrowserEnabledKey)
      if !isChatBrowserEnabled {
        chatWebView = nil
      }
    }
  }

  let registration: any BridgeServiceRegistrationManaging
  let clientFactory: BridgeServiceClientFactory
  let pollInterval: Duration?
  let connectionRetryDelay: Duration
  let maximumConnectionAttempts: Int
  var client: (any BridgeServiceClientProtocol)?
  var pollingTask: Task<Void, Never>?
  var started = false
  var stopped = false

  private static let chatBrowserEnabledKey = "chatBrowserEnabled"

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
    maximumConnectionAttempts: Int = 20
  ) {
    precondition(maximumConnectionAttempts > 0)
    self.registration = registration
    self.clientFactory = clientFactory
    self.pollInterval = pollInterval
    self.connectionRetryDelay = connectionRetryDelay
    self.maximumConnectionAttempts = maximumConnectionAttempts
    registrationStatus = registration.status
    isChatBrowserEnabled =
      UserDefaults.standard.object(forKey: Self.chatBrowserEnabledKey)
      as? Bool ?? true
  }

  deinit {
    pollingTask?.cancel()
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
}
