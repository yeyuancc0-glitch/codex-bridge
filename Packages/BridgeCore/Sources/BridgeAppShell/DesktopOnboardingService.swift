import BridgeCodexRPC
import BridgeDomain
import BridgePresentation
import BridgeProjects
import BridgeSecurity
import BridgeTunnel
import Foundation
import Security

enum DesktopOnboardingError: LocalizedError, Equatable, Sendable {
  case invalidTransition
  case codexUnavailable
  case invalidLoginResponse
  case invalidAuthenticationURL
  case invalidRuntimeKey
  case invalidHTTPSEndpoint
  case randomGenerationFailed

  var errorDescription: String? {
    switch self {
    case .invalidTransition:
      "当前步骤仍有未完成的必要条件。"
    case .codexUnavailable:
      "Codex app-server 尚未通过系统检测。"
    case .invalidLoginResponse:
      "Codex 返回了无法安全处理的登录响应。"
    case .invalidAuthenticationURL:
      "Codex 登录地址不是有效的 HTTPS 地址。"
    case .invalidRuntimeKey:
      "Runtime Key 格式无效；它不会被保存。"
    case .invalidHTTPSEndpoint:
      "HTTPS Endpoint 或认证配置无效。"
    case .randomGenerationFailed:
      "无法生成本机 MCP 认证 Secret。"
    }
  }
}

protocol DesktopOnboardingBackend: Sendable {
  func onboardingProject() async throws -> ProjectSummaryDTO?
  func registerOnboardingProject() async throws -> ProjectSummaryDTO?
  func updateOnboardingProjectPolicy(
    projectID: ProjectID,
    policy: ProjectAccessPolicy
  ) async throws
  func configureOnboardingTransport(
    _ configuration: DesktopOnboardingTransportConfiguration
  ) async throws -> URL
  func testOnboardingTransport() async throws
  func stopOnboardingTransport() async throws
}

extension LiveBridgeAppBackend: DesktopOnboardingBackend {}

actor DesktopOnboardingService: OnboardingActionHandling {
  private let dataDirectoryURL: URL
  private let backend: any DesktopOnboardingBackend
  private let system: any DesktopSystemServing
  private let capabilities: any DesktopSystemCapabilityInspecting
  private let secretStore: any SecretStore
  private var continuations: [UUID: AsyncStream<OnboardingPresentation>.Continuation] = [:]
  private var record = DesktopOnboardingRecord.fresh()
  private var checks: [OnboardingCheckPresentation] = []
  private var accountResponse: GetAccountResponse?
  private var codexClient: CodexAppServerClient?
  private var codexEvents: Task<Void, Never>?
  private var bootstrapTask: Task<Void, Never>?
  private var loginID: String?
  private var isBusy = true
  private var hasStoredRuntimeKey = false
  private var hasStoredManualSecret = false
  private var localMCPURL: URL?
  private var hasStarted = false
  private var isShuttingDown = false

  init(
    dataDirectoryURL: URL,
    backend: any DesktopOnboardingBackend,
    system: any DesktopSystemServing,
    capabilities: any DesktopSystemCapabilityInspecting = DesktopSystemCapabilityService(),
    secretStore: any SecretStore = KeychainSecretStore()
  ) {
    self.dataDirectoryURL = dataDirectoryURL
    self.backend = backend
    self.system = system
    self.capabilities = capabilities
    self.secretStore = secretStore
  }

  func stateUpdates() -> AsyncStream<OnboardingPresentation> {
    let identifier = UUID()
    let pair = AsyncStream.makeStream(
      of: OnboardingPresentation.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuations[identifier] = pair.continuation
    pair.continuation.yield(presentation())
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.removeContinuation(identifier) }
    }
    beginBootstrapIfNeeded()
    return pair.stream
  }

  func handle(_ action: OnboardingAction) async throws {
    guard hasStarted, !isShuttingDown else { throw DesktopBackendError.notReady }
    switch action {
    case .advance:
      try await advance()
    case .goBack:
      try goBack()
    case .runSystemChecks:
      await runSystemChecks()
    case .startCodexLogin:
      try await startCodexLogin()
    case .cancelCodexLogin:
      try await cancelCodexLogin()
    case .selectConnectionMode(let mode):
      try await selectConnectionMode(mode)
    case .saveTunnelConfiguration(let tunnelID, let runtimeKey):
      try await saveTunnelConfiguration(tunnelID: tunnelID, runtimeKey: runtimeKey)
    case .saveManualHTTPSConfiguration(let endpoint, let authenticationSecret):
      try await saveManualHTTPSConfiguration(
        endpoint: endpoint,
        authenticationSecret: authenticationSecret
      )
    case .copyLocalMCPEndpoint:
      try await copyLocalMCPEndpoint()
    case .addProject:
      try await addProject()
    case .setSecurityDefaults(let write, let network):
      try await setSecurityDefaults(write: write, network: network)
    case .testConnection:
      try await testConnection()
    case .finish:
      try finish()
    }
  }

  func currentPresentation() -> OnboardingPresentation {
    presentation()
  }

  func shutdown() async {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    bootstrapTask?.cancel()
    await bootstrapTask?.value
    bootstrapTask = nil
    codexEvents?.cancel()
    codexEvents = nil
    await codexClient?.stop()
    codexClient = nil
    let active = continuations.values
    continuations.removeAll(keepingCapacity: false)
    for continuation in active { continuation.finish() }
  }

  private func beginBootstrapIfNeeded() {
    guard bootstrapTask == nil, !hasStarted, !isShuttingDown else { return }
    bootstrapTask = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try DesktopDataStore.prepare(at: self.dataDirectoryURL)
        let store = DesktopOnboardingStore(directoryURL: self.dataDirectoryURL)
        let record = try store.load()
        await self.finishBootstrap(record)
      } catch {
        await self.failBootstrap()
      }
    }
  }

  private func finishBootstrap(_ loaded: DesktopOnboardingRecord) async {
    guard !isShuttingDown else { return }
    record = loaded
    hasStoredRuntimeKey = storedRuntimeKey() != nil
    hasStoredManualSecret = storedManualAuthorization() != nil
    if let project = try? await backend.onboardingProject() {
      record.projectID = project.id.rawValue
      record.projectName = project.name
    }
    guard !isShuttingDown else { return }
    if record.completed {
      do {
        localMCPURL = try await backend.configureOnboardingTransport(
          try transportConfiguration())
        try await backend.testOnboardingTransport()
      } catch {
        record.completed = false
        record.currentStep = .connectionTest
        record.connectionTestSucceeded = false
        do {
          try persist()
        } catch {
          failBootstrap()
          return
        }
      }
    }
    guard !isShuttingDown else { return }
    hasStarted = true
    isBusy = false
    bootstrapTask = nil
    publish()
  }

  private func failBootstrap() {
    bootstrapTask = nil
    hasStarted = false
    isBusy = false
    checks = [
      OnboardingCheckPresentation(
        id: "bootstrap",
        title: "无法读取首次设置",
        detail: "Bridge 不会在持久化状态不可信时跳过引导。",
        status: .blocked
      )
    ]
    publish()
  }

  private func advance() async throws {
    guard canContinue else { throw DesktopOnboardingError.invalidTransition }
    guard let next = OnboardingStep(rawValue: record.currentStep.rawValue + 1) else {
      throw DesktopOnboardingError.invalidTransition
    }
    record.currentStep = next
    try persist()
    publish()
    if next == .systemCheck { await runSystemChecks() }
  }

  private func goBack() throws {
    guard record.currentStep.rawValue > 0,
      let previous = OnboardingStep(rawValue: record.currentStep.rawValue - 1)
    else {
      throw DesktopOnboardingError.invalidTransition
    }
    record.currentStep = previous
    try persist()
    publish()
  }

  private func runSystemChecks() async {
    guard !isBusy else { return }
    isBusy = true
    checks = [
      OnboardingCheckPresentation(
        id: "running",
        title: "正在检查本机能力",
        detail: "启动隔离的 app-server 会话并协商账号与模型接口。",
        status: .checking
      )
    ]
    publish()
    codexEvents?.cancel()
    codexEvents = nil
    await codexClient?.stop()
    let inspection = await capabilities.inspect()
    guard !isShuttingDown else {
      await inspection.client?.stop()
      return
    }
    checks = inspection.checks
    accountResponse = inspection.account
    codexClient = inspection.client
    installEventConsumer(for: inspection.client)
    isBusy = false
    publish()
  }

  private func installEventConsumer(for client: CodexAppServerClient?) {
    guard let client else { return }
    codexEvents = Task { [weak self, client] in
      for await event in client.events {
        guard !Task.isCancelled else { return }
        await self?.consume(event, from: client)
      }
    }
  }

  private func consume(_ event: AppServerEvent, from client: CodexAppServerClient) async {
    switch event {
    case .serverRequest:
      codexEvents?.cancel()
      codexEvents = nil
      codexClient = nil
      await client.stop()
      accountResponse = nil
      loginID = nil
      publish()
    case .notification(let notification):
      guard let decoded = try? notification.decodedCodexAccountNotification() else { return }
      switch decoded {
      case .accountUpdated(_), .rateLimitsUpdated(_):
        await refreshAccount(using: client)
      case .loginCompleted(let completion):
        guard completion.loginId == nil || completion.loginId == loginID else { return }
        loginID = nil
        if completion.success { await refreshAccount(using: client) } else { publish() }
      case .unknown:
        break
      }
    }
  }

  private func refreshAccount(using client: CodexAppServerClient) async {
    accountResponse = try? await client.readAccount(GetAccountParams(refreshToken: false))
    publish()
  }

  private func startCodexLogin() async throws {
    guard loginID == nil, let client = codexClient else {
      throw DesktopOnboardingError.codexUnavailable
    }
    isBusy = true
    publish()
    defer {
      isBusy = false
      publish()
    }
    let response = try await client.startChatGPTLogin()
    guard response.type == "chatgpt", let loginID = response.loginId,
      !loginID.isEmpty, loginID.utf8.count <= 1_024,
      let rawURL = response.authUrl,
      let url = Self.validAuthenticationURL(rawURL)
    else {
      throw DesktopOnboardingError.invalidLoginResponse
    }
    self.loginID = loginID
    guard await system.open(url) else {
      self.loginID = nil
      _ = try? await client.cancelLogin(CancelLoginParams(loginId: loginID))
      throw DesktopOnboardingError.invalidAuthenticationURL
    }
  }

  private func cancelCodexLogin() async throws {
    guard let loginID, let client = codexClient else {
      throw DesktopOnboardingError.invalidTransition
    }
    _ = try await client.cancelLogin(CancelLoginParams(loginId: loginID))
    self.loginID = nil
    publish()
  }

  private func selectConnectionMode(_ mode: OnboardingConnectionMode) async throws {
    if record.connectionMode != mode {
      try await backend.stopOnboardingTransport()
      localMCPURL = nil
      record.connectionMode = mode
      record.connectionTestSucceeded = false
    }
    try persist()
    if mode == .localDevelopment, localMCPURL == nil {
      do {
        localMCPURL = try await backend.configureOnboardingTransport(
          try transportConfiguration())
      } catch {
        publish()
        throw error
      }
    }
    publish()
  }

  private func saveTunnelConfiguration(tunnelID: String, runtimeKey: String) async throws {
    guard record.connectionMode == .secureTunnel else {
      throw DesktopOnboardingError.invalidTransition
    }
    let validatedID = try TunnelID(validating: tunnelID)
    if runtimeKey.isEmpty {
      guard hasStoredRuntimeKey else { throw DesktopOnboardingError.invalidRuntimeKey }
    } else {
      guard Self.isValidRuntimeKey(runtimeKey) else {
        throw DesktopOnboardingError.invalidRuntimeKey
      }
      try secretStore.store(
        Data(runtimeKey.utf8),
        for: .runtimeKey(profileID: record.profileID)
      )
      hasStoredRuntimeKey = true
    }
    record.tunnelID = validatedID.rawValue
    record.connectionTestSucceeded = false
    try persist()
    publish()
  }

  private func saveManualHTTPSConfiguration(
    endpoint: String,
    authenticationSecret: String
  ) async throws {
    guard record.connectionMode == .manualHTTPS,
      let url = Self.validManualHTTPSURL(endpoint)
    else {
      throw DesktopOnboardingError.invalidHTTPSEndpoint
    }
    if authenticationSecret.isEmpty {
      guard hasStoredManualSecret else {
        throw DesktopOnboardingError.invalidHTTPSEndpoint
      }
    } else {
      guard ManualHTTPSTransport.isValidAuthorization(authenticationSecret) else {
        throw DesktopOnboardingError.invalidHTTPSEndpoint
      }
      try secretStore.store(Data(authenticationSecret.utf8), for: manualSecretReference())
      hasStoredManualSecret = true
    }
    record.manualHTTPSEndpoint = url.absoluteString
    record.connectionTestSucceeded = false
    try persist()
    do {
      localMCPURL = try await backend.configureOnboardingTransport(
        try transportConfiguration())
      publish()
    } catch {
      localMCPURL = nil
      publish()
      throw error
    }
  }

  private func copyLocalMCPEndpoint() async throws {
    guard record.connectionMode == .manualHTTPS || record.connectionMode == .localDevelopment,
      let localMCPURL,
      await system.copyToPasteboard(localMCPURL.absoluteString)
    else {
      throw DesktopBackendError.operationFailed
    }
  }

  private func addProject() async throws {
    guard let project = try await backend.registerOnboardingProject() else { return }
    record.projectID = project.id.rawValue
    record.projectName = project.name
    record.securityDefaultsSaved = false
    record.connectionTestSucceeded = false
    try persist()
    publish()
  }

  private func setSecurityDefaults(
    write: OnboardingPermissionDefault,
    network: OnboardingPermissionDefault
  ) async throws {
    guard let rawProjectID = record.projectID else {
      throw DesktopOnboardingError.invalidTransition
    }
    let policy = ProjectAccessPolicy(
      read: .allowed,
      write: Self.permission(write),
      network: Self.permission(network)
    )
    try await backend.updateOnboardingProjectPolicy(
      projectID: ProjectID(rawValue: rawProjectID),
      policy: policy
    )
    record.writeDefault = write
    record.networkDefault = network
    record.securityDefaultsSaved = true
    record.connectionTestSucceeded = false
    try persist()
    publish()
  }

  private func testConnection() async throws {
    guard record.projectID != nil, record.securityDefaultsSaved else {
      throw DesktopOnboardingError.invalidTransition
    }
    isBusy = true
    record.connectionTestSucceeded = false
    publish()
    defer {
      isBusy = false
      publish()
    }
    do {
      localMCPURL = try await backend.configureOnboardingTransport(
        try transportConfiguration())
      try await backend.testOnboardingTransport()
    } catch {
      localMCPURL = nil
      try? await backend.stopOnboardingTransport()
      throw error
    }
    record.connectionTestSucceeded = true
    try persist()
  }

  private func finish() throws {
    guard record.currentStep == .completion, record.connectionTestSucceeded else {
      throw DesktopOnboardingError.invalidTransition
    }
    record.completed = true
    try persist()
    publish()
  }

  private func mcpSecret() throws -> String {
    let reference = SecretReference.mcpPathSecret(profileID: record.profileID)
    if let data = try? secretStore.load(reference),
      let value = String(data: data, encoding: .utf8),
      Self.isValidMCPSecret(value)
    {
      return value
    }
    let value = try Self.generateMCPSecret()
    try secretStore.store(Data(value.utf8), for: reference)
    return value
  }

  private func manualSecretReference() -> SecretReference {
    SecretReference(
      rawValue: "manual-https-auth.\(record.profileID.uuidString.lowercased())"
    )
  }

  private func persist() throws {
    try DesktopOnboardingStore(directoryURL: dataDirectoryURL).save(record)
  }

  private func publish() {
    let value = presentation()
    for continuation in continuations.values { continuation.yield(value) }
  }

  private func presentation() -> OnboardingPresentation {
    OnboardingPresentation(
      currentStep: record.currentStep,
      isFinished: record.completed,
      completedSteps: completedSteps,
      checks: checks,
      account: accountPresentation,
      connectionMode: record.connectionMode,
      tunnelID: record.tunnelID ?? "",
      hasStoredRuntimeKey: hasStoredRuntimeKey,
      localMCPURLDescription: localMCPURL.map(Self.publicLocalMCPURL),
      projectName: record.projectName,
      writeDefault: record.writeDefault,
      networkDefault: record.networkDefault,
      connectionStatus: connectionPresentation,
      isBusy: isBusy,
      canContinue: canContinue,
      canGoBack: record.currentStep != .welcome && !record.completed,
      primaryActionTitle: record.currentStep == .completion ? "进入主窗口" : "继续"
    )
  }

  private var completedSteps: Set<OnboardingStep> {
    Set(OnboardingStep.allCases.filter { $0.rawValue < record.currentStep.rawValue })
  }

  private var canContinue: Bool {
    guard hasStarted, !record.completed else { return false }
    return switch record.currentStep {
    case .welcome: true
    case .systemCheck: requiredChecksPassed
    case .codexAccount: accountResponse?.account != nil
    case .connectionMode: record.connectionMode != nil
    case .connectionConfiguration: connectionConfigurationSaved
    case .project: record.projectID != nil
    case .securityDefaults: record.securityDefaultsSaved
    case .connectionTest: record.connectionTestSucceeded
    case .completion: record.connectionTestSucceeded
    }
  }

  private var requiredChecksPassed: Bool {
    !checks.isEmpty
      && checks.filter { $0.id != "tunnel-helper" }.allSatisfy { $0.status == .ready }
  }

  private var connectionConfigurationSaved: Bool {
    switch record.connectionMode {
    case .secureTunnel:
      record.tunnelID != nil && hasStoredRuntimeKey
    case .manualHTTPS:
      record.manualHTTPSEndpoint != nil && hasStoredManualSecret
    case .localDevelopment:
      true
    case nil:
      false
    }
  }

  private var accountPresentation: OnboardingAccountPresentation {
    if loginID != nil {
      return OnboardingAccountPresentation(
        status: .checking,
        title: "等待 ChatGPT 登录",
        detail: "已在系统浏览器打开官方登录流程。",
        loginInProgress: true
      )
    }
    guard let response = accountResponse, let account = response.account else {
      return OnboardingAccountPresentation(
        status: codexClient == nil ? .pending : .blocked,
        title: "尚未登录 Codex",
        detail: "使用 ChatGPT 官方账号完成登录后继续。"
      )
    }
    switch account.type {
    case "chatgpt":
      return OnboardingAccountPresentation(
        status: .ready,
        title: "ChatGPT 登录已就绪",
        detail: "计划：\(account.planType ?? "未知")"
      )
    case "apiKey":
      return OnboardingAccountPresentation(
        status: .warning,
        title: "Codex 当前使用 API Key",
        detail: "可以继续，但这不是本方案推荐的 ChatGPT 官方登录路径。"
      )
    default:
      return OnboardingAccountPresentation(
        status: .warning,
        title: "Codex 使用其他认证模式",
        detail: "认证类型：\(account.type)"
      )
    }
  }

  private var connectionPresentation: OnboardingCheckPresentation {
    if record.connectionTestSucceeded {
      return OnboardingCheckPresentation(
        id: "connection",
        title: "本地 MCP 连接测试通过",
        detail: "严格 SDK client 已完成 initialize 并核对受限工具目录。",
        status: .ready
      )
    }
    return OnboardingCheckPresentation(
      id: "connection",
      title: "连接尚未通过",
      detail: record.connectionMode == .localDevelopment
        ? "运行真实回环 MCP initialize 与工具目录检查。"
        : "Secure Tunnel 与自备 HTTPS 仍需完成对应的外部链路。",
      status: .pending
    )
  }

  private func removeContinuation(_ identifier: UUID) {
    continuations[identifier] = nil
  }

  private static func permission(_ value: OnboardingPermissionDefault) -> ProjectPermission {
    switch value {
    case .denied: .denied
    case .localApproval: .requiresLocalApproval
    case .allowed: .allowed
    }
  }

  private static func validAuthenticationURL(_ value: String) -> URL? {
    guard value.utf8.count <= 8_192,
      let components = URLComponents(string: value),
      components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      let url = components.url
    else {
      return nil
    }
    return url
  }

  private static func validManualHTTPSURL(_ value: String) -> URL? {
    guard let components = URLComponents(string: value),
      components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.percentEncodedQuery == nil,
      components.percentEncodedPath == "/mcp",
      let url = components.url
    else {
      return nil
    }
    return url
  }

  private static func isValidRuntimeKey(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= KeychainSecretStore.maximumSecretBytes
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95
      }
  }

  private func storedRuntimeKey() -> String? {
    guard let data = try? secretStore.load(.runtimeKey(profileID: record.profileID)),
      let value = String(data: data, encoding: .utf8),
      Self.isValidRuntimeKey(value)
    else {
      return nil
    }
    return value
  }

  private func storedManualAuthorization() -> String? {
    guard let data = try? secretStore.load(manualSecretReference()),
      let value = String(data: data, encoding: .utf8),
      ManualHTTPSTransport.isValidAuthorization(value)
    else {
      return nil
    }
    return value
  }

  private func transportConfiguration() throws -> DesktopOnboardingTransportConfiguration {
    switch record.connectionMode {
    case .localDevelopment:
      return .local(pathSecret: try mcpSecret())
    case .manualHTTPS:
      guard let endpoint = record.manualHTTPSEndpoint.flatMap(URL.init(string:)),
        let authorization = storedManualAuthorization()
      else {
        throw DesktopOnboardingError.invalidHTTPSEndpoint
      }
      return .manual(
        pathSecret: try mcpSecret(),
        endpoint: endpoint,
        authorization: authorization
      )
    case .secureTunnel:
      guard let rawTunnelID = record.tunnelID, storedRuntimeKey() != nil else {
        throw DesktopOnboardingError.invalidRuntimeKey
      }
      return .secure(
        headerSecret: try mcpSecret(),
        tunnelID: try TunnelID(validating: rawTunnelID),
        runtimeKeyReference: .runtimeKey(profileID: record.profileID)
      )
    case nil:
      throw DesktopOnboardingError.invalidTransition
    }
  }

  private static func publicLocalMCPURL(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "127.0.0.1"
    }
    if components.percentEncodedPath.hasPrefix("/mcp/") {
      return publicOrigin(components) + "/mcp/<本机认证 Secret>"
    }
    return components.string ?? "127.0.0.1"
  }

  private static func publicOrigin(_ components: URLComponents) -> String {
    let scheme = components.scheme ?? "http"
    let host = components.host ?? "127.0.0.1"
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  private static func generateMCPSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw DesktopOnboardingError.randomGenerationFailed
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func isValidMCPSecret(_ value: String) -> Bool {
    value.utf8.count == 43
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95
      }
  }
}
