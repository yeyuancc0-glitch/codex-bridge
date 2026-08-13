import Foundation

public enum OnboardingStep: Int, CaseIterable, Codable, Hashable, Sendable {
  case welcome
  case systemCheck
  case codexAccount
  case connectionMode
  case connectionConfiguration
  case project
  case securityDefaults
  case connectionTest
  case completion

  public var title: String {
    switch self {
    case .welcome: "欢迎"
    case .systemCheck: "系统检测"
    case .codexAccount: "Codex 登录"
    case .connectionMode: "连接模式"
    case .connectionConfiguration: "连接配置"
    case .project: "添加项目"
    case .securityDefaults: "安全默认值"
    case .connectionTest: "连接测试"
    case .completion: "完成"
    }
  }

  public var detail: String {
    switch self {
    case .welcome:
      "在本机建立 ChatGPT、Codex、项目白名单和审批边界。"
    case .systemCheck:
      "核对系统、Codex app-server、Git、本地端口和 Tunnel helper。"
    case .codexAccount:
      "复用 Codex 的 ChatGPT 官方登录，不读取或复制登录 Token。"
    case .connectionMode:
      "选择 ChatGPT 网页如何安全访问这台 Mac。"
    case .connectionConfiguration:
      "保存传输配置；敏感凭证只进入本机 Keychain。"
    case .project:
      "登记第一个允许 Bridge 读取的项目根目录。"
    case .securityDefaults:
      "确定项目写入和网络访问是否需要本机确认。"
    case .connectionTest:
      "用真实 initialize、工具列表和传输健康状态验证整条链路。"
    case .completion:
      "确认首个安全配置已经持久化并可以恢复。"
    }
  }
}

public enum OnboardingItemStatus: String, Codable, Equatable, Sendable {
  case pending
  case checking
  case ready
  case warning
  case blocked

  public var systemImage: String {
    switch self {
    case .pending: "circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .ready: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .blocked: "xmark.octagon.fill"
    }
  }
}

public struct OnboardingCheckPresentation: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let status: OnboardingItemStatus

  public init(id: String, title: String, detail: String, status: OnboardingItemStatus) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
  }
}

public enum OnboardingConnectionMode: String, CaseIterable, Codable, Hashable, Sendable {
  case secureTunnel
  case manualHTTPS
  case localDevelopment

  public var title: String {
    switch self {
    case .secureTunnel: "OpenAI Secure MCP Tunnel"
    case .manualHTTPS: "自备 HTTPS Endpoint"
    case .localDevelopment: "仅本机开发"
    }
  }

  public var detail: String {
    switch self {
    case .secureTunnel:
      "推荐。无需自建服务器；需要最小权限 Restricted Runtime Key。"
    case .manualHTTPS:
      "高级模式。由你负责公网域名、TLS、强认证和可用性。"
    case .localDevelopment:
      "只用于 Inspector 和本机调试；ChatGPT 网页无法直接访问 localhost。"
    }
  }
}

public enum OnboardingPermissionDefault: String, CaseIterable, Codable, Hashable, Sendable {
  case denied
  case localApproval
  case allowed

  public var title: String {
    switch self {
    case .denied: "不允许"
    case .localApproval: "每次本机确认"
    case .allowed: "允许"
    }
  }
}

public struct OnboardingAccountPresentation: Codable, Equatable, Sendable {
  public let status: OnboardingItemStatus
  public let title: String
  public let detail: String
  public let loginInProgress: Bool

  public init(
    status: OnboardingItemStatus,
    title: String,
    detail: String,
    loginInProgress: Bool = false
  ) {
    self.status = status
    self.title = title
    self.detail = detail
    self.loginInProgress = loginInProgress
  }
}

public struct OnboardingPresentation: Codable, Equatable, Sendable {
  public let currentStep: OnboardingStep
  public let isFinished: Bool
  public let completedSteps: Set<OnboardingStep>
  public let checks: [OnboardingCheckPresentation]
  public let account: OnboardingAccountPresentation
  public let connectionMode: OnboardingConnectionMode?
  public let tunnelID: String
  public let hasStoredRuntimeKey: Bool
  public let projectName: String?
  public let writeDefault: OnboardingPermissionDefault
  public let networkDefault: OnboardingPermissionDefault
  public let connectionStatus: OnboardingCheckPresentation
  public let isBusy: Bool
  public let canContinue: Bool
  public let canGoBack: Bool
  public let primaryActionTitle: String

  public init(
    currentStep: OnboardingStep,
    isFinished: Bool = false,
    completedSteps: Set<OnboardingStep> = [],
    checks: [OnboardingCheckPresentation] = [],
    account: OnboardingAccountPresentation,
    connectionMode: OnboardingConnectionMode? = nil,
    tunnelID: String = "",
    hasStoredRuntimeKey: Bool = false,
    projectName: String? = nil,
    writeDefault: OnboardingPermissionDefault = .localApproval,
    networkDefault: OnboardingPermissionDefault = .denied,
    connectionStatus: OnboardingCheckPresentation,
    isBusy: Bool = false,
    canContinue: Bool = false,
    canGoBack: Bool = false,
    primaryActionTitle: String = "继续"
  ) {
    self.currentStep = currentStep
    self.isFinished = isFinished
    self.completedSteps = completedSteps
    self.checks = checks
    self.account = account
    self.connectionMode = connectionMode
    self.tunnelID = tunnelID
    self.hasStoredRuntimeKey = hasStoredRuntimeKey
    self.projectName = projectName
    self.writeDefault = writeDefault
    self.networkDefault = networkDefault
    self.connectionStatus = connectionStatus
    self.isBusy = isBusy
    self.canContinue = canContinue
    self.canGoBack = canGoBack
    self.primaryActionTitle = primaryActionTitle
  }

  public static var loading: OnboardingPresentation {
    OnboardingPresentation(
      currentStep: .welcome,
      account: OnboardingAccountPresentation(
        status: .pending,
        title: "尚未检测 Codex 登录",
        detail: "系统检测完成后读取官方账号状态。"
      ),
      connectionStatus: OnboardingCheckPresentation(
        id: "connection",
        title: "尚未测试连接",
        detail: "完成传输配置和项目登记后再测试。",
        status: .pending
      ),
      isBusy: true
    )
  }
}

public enum OnboardingAction: Equatable, Sendable {
  case advance
  case goBack
  case runSystemChecks
  case startCodexLogin
  case cancelCodexLogin
  case selectConnectionMode(OnboardingConnectionMode)
  case saveTunnelConfiguration(tunnelID: String, runtimeKey: String)
  case saveManualHTTPSConfiguration(endpoint: String, authenticationSecret: String)
  case addProject
  case setSecurityDefaults(
    write: OnboardingPermissionDefault,
    network: OnboardingPermissionDefault
  )
  case testConnection
  case finish
}

public protocol OnboardingActionHandling: Sendable {
  func handle(_ action: OnboardingAction) async throws
}
