import AppKit
import BridgeIPC
import BridgeMCP
import Foundation
import SwiftUI

public enum BridgeServiceNavigation: String, CaseIterable, Identifiable, Sendable {
  case overview
  case tasks
  case projects
  case connections
  case settings

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "概览"
    case .tasks: "任务"
    case .projects: "项目"
    case .connections: "连接"
    case .settings: "设置"
    }
  }

  var symbol: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .tasks: "list.bullet.rectangle"
    case .projects: "folder"
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
  @Published public internal(set) var threads: [MCPThreadSummary] = []
  @Published public internal(set) var selectedThread: MCPThreadReadPage?
  @Published public internal(set) var selectedProjectID: String?
  @Published public internal(set) var isRefreshing = false
  @Published public internal(set) var lastRefreshAt: Date?
  @Published public var errorMessage: String?

  let registration: any BridgeServiceRegistrationManaging
  let clientFactory: BridgeServiceClientFactory
  let pollInterval: Duration?
  let connectionRetryDelay: Duration
  let maximumConnectionAttempts: Int
  var client: (any BridgeServiceClientProtocol)?
  var pollingTask: Task<Void, Never>?
  var started = false
  var stopped = false

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
  }

  deinit {
    pollingTask?.cancel()
  }

  public var pendingLocalTaskCount: Int {
    tasks.lazy.filter { $0.status == "awaiting_local_approval" }.count
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
    return "\(components.scheme ?? "http")://\(host)\(port)/mcp/<本机认证 Secret>"
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
