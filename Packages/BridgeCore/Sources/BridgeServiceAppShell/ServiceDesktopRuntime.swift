import BridgeIPC
import BridgeMCP
import Foundation
import WebKit

extension BridgeServiceAppModel {
  func startAsync() async {
    guard !started, !stopped else { return }
    started = true
    registrationStatus = registration.status
    switch registrationStatus {
    case .enabled:
      await connect(includeCatalog: true)
    case .notRegistered:
      await enableBackgroundService()
    case .requiresApproval:
      connectionState = .requiresApproval
    case .notFound:
      connectionState = .unavailable
      errorMessage = "App Bundle 中没有找到 Codex Bridge 后台 Service。"
    }
  }

  public func shutdownUI() async {
    guard !stopped else { return }
    stopped = true
    started = false
    pollingTask?.cancel()
    pollingTask = nil
    cancelChatBrowserSleep()
    releaseChatWebView()
    closeConversation()
    await closeClient()
    connectionState = .idle
  }

  func enableBackgroundService() async {
    guard !stopped else { return }
    errorMessage = nil
    registrationStatus = registration.status
    if registrationStatus == .enabled {
      await connect(includeCatalog: true)
      return
    }

    connectionState = .registering
    do {
      try registration.register()
    } catch {
      registrationStatus = registration.status
      guard registrationStatus == .enabled else {
        connectionState =
          registrationStatus == .requiresApproval
          ? .requiresApproval
          : .unavailable
        errorMessage = Self.message(error)
        return
      }
    }

    registrationStatus = registration.status
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      return
    }
    await connect(includeCatalog: true)
  }

  func disableBackgroundService() async {
    errorMessage = nil
    pollingTask?.cancel()
    pollingTask = nil
    closeConversation()
    await closeClient()
    do {
      if registration.status != .notRegistered {
        try await registration.unregister()
      }
      registrationStatus = registration.status
      connectionState = .idle
      serviceStatus = nil
      projects = []
      agentProviders = []
      agentInstallations = []
      isManagingAgents = false
      tasks = []
      approvals = []
      mcpClients = []
      models = []
      modelPreferences = nil
      customInstructions = nil
      modelCatalogError = nil
      threads = []
      skills = []
      selectedThread = nil
      selectedTaskID = nil
      selectedProjectID = nil
    } catch {
      registrationStatus = registration.status
      connectionState = .unavailable
      errorMessage = Self.message(error)
    }
  }

  func refresh(
    silent: Bool,
    includeCatalog: Bool
  ) async {
    guard !stopped, !isRefreshing else { return }
    registrationStatus = registration.status
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      return
    }
    guard let client else {
      await connect(includeCatalog: includeCatalog)
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }
    do {
      serviceStatus = try await client.status()
      connectionState = .connected
      lastRefreshAt = Date()
      if !silent { errorMessage = nil }
      await refreshCollections(
        client: client,
        includeCatalog: includeCatalog,
        includeThreads: !silent
      )
    } catch {
      await closeClient()
      connectionState = .unavailable
      if !silent { errorMessage = Self.message(error) }
    }
  }

  func connect(includeCatalog: Bool) async {
    pollingTask?.cancel()
    pollingTask = nil
    await closeClient()
    registrationStatus = registration.status
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      return
    }

    connectionState = .connecting
    var lastError: (any Error)?
    for attempt in 0..<maximumConnectionAttempts {
      guard !stopped, registration.status == .enabled else { return }
      let candidate = clientFactory()
      do {
        serviceStatus = try await candidate.status()
        client = candidate
        connectionState = .connected
        registrationStatus = .enabled
        lastRefreshAt = Date()
        errorMessage = nil
        await refreshCollections(
          client: candidate,
          includeCatalog: includeCatalog,
          includeThreads: true
        )
        startPolling()
        return
      } catch {
        lastError = error
        await candidate.close()
        guard attempt + 1 < maximumConnectionAttempts else { break }
        do {
          try await Task.sleep(for: connectionRetryDelay)
        } catch {
          return
        }
      }
    }

    registrationStatus = registration.status
    connectionState =
      registrationStatus == .requiresApproval
      ? .requiresApproval
      : .unavailable
    if let lastError {
      errorMessage = Self.message(lastError)
    }
  }

  func refreshCollections(
    client: any BridgeServiceClientProtocol,
    includeCatalog: Bool,
    includeThreads: Bool
  ) async {
    async let projectResult = optional { try await client.projects() }
    async let agentCatalogResult = optional { try await client.agentCatalog() }
    async let taskResult = optional {
      try await client.tasks(IPCTaskListRequest(limit: 200))
    }
    async let approvalResult = optional { try await client.approvals(taskID: nil) }
    async let directApprovalResult = optional { try await client.pendingDirectApprovals() }
    async let directApprovalModeResult = optional { try await client.directApprovalMode() }
    async let mcpClientResult = optional { try await client.mcpClients() }

    if let value = await projectResult {
      projects = value
      reconcileProjectSelection()
      if selectedProjectID == nil {
        selectedProjectID =
          value.first(where: { $0.projectID == serviceStatus?.workbenchProjectID })?.projectID
          ?? value.first?.projectID
      }
    }

    if let value = await agentCatalogResult {
      agentProviders = value.providers
      agentInstallations = value.installations
    }

    if let projectID = selectedProjectID, projectDetails[projectID] == nil,
      let detail = await optional({ try await client.projectCommands(projectID: projectID) }),
      selectedProjectID == projectID
    {
      projectDetails[projectID] = detail
    }

    var shouldRefreshThreads = includeThreads || threadCatalogRefreshDue()
    if let value = await taskResult {
      shouldRefreshThreads =
        shouldRefreshThreads || Self.taskCatalogChanged(from: tasks, to: value)
      tasks = value
      reconcileTaskSelection()
      if let activeAgentTask = value.first(where: { $0.isExternalAgentTask && $0.isActive }),
        selectedTaskID != activeAgentTask.taskID || conversation?.taskID != activeAgentTask.taskID
      {
        selectedProjectID = activeAgentTask.projectID
        persistWorkbenchProjectSelection(activeAgentTask.projectID)
        selectedTaskID = activeAgentTask.taskID
        selectedThreadID = nil
        selectedThread = nil
        openConversation(taskID: activeAgentTask.taskID)
      } else if let activeTask = value.first(where: \.isRunning),
        let threadID = activeTask.threadID,
        selectedThreadID != threadID || conversation?.taskID != activeTask.taskID
      {
        selectedProjectID = activeTask.projectID
        persistWorkbenchProjectSelection(activeTask.projectID)
        selectedTaskID = activeTask.taskID
        selectedThreadID = threadID
        selectedThread = nil
        openConversation(taskID: activeTask.taskID)
      }
    }

    if shouldRefreshThreads, let projectID = selectedProjectID {
      lastThreadCatalogRefreshAt = Date()
      async let skillResult = optional { try await client.skills(projectID: projectID) }
      let threadPage = await optional {
        try await client.threads(IPCThreadListRequest(projectID: projectID, limit: 100))
      }
      if selectedProjectID == projectID, let value = await skillResult {
        skills = value.skills
      }
      if selectedProjectID == projectID, let threadPage {
        threads = threadPage.threads
        reconcileThreadSelection()
      }
    }

    if let value = await approvalResult {
      approvals = value
    }
    if let value = await directApprovalResult {
      directApprovals = value
    }
    if let value = await directApprovalModeResult {
      directApprovalMode = value
    }
    if let value = await mcpClientResult {
      mcpClients = value
    }
    if includeCatalog {
      do {
        let catalog = try await client.modelCatalog()
        models = catalog.models
        modelPreferences = catalog.preferences
        modelCatalogError = nil
      } catch {
        models = []
        modelPreferences = nil
        modelCatalogError = Self.message(error)
      }
      if let value = await optional({ try await client.customInstructions() }) {
        customInstructions = value
      }
    }
  }

  func reconcileThreadSelection() {
    guard let selectedThreadID else { return }
    let remainsVisible = threads.contains { $0.threadID == selectedThreadID }
    let belongsToTask = tasks.contains { $0.threadID == selectedThreadID }
    guard !remainsVisible, !belongsToTask else { return }
    self.selectedThreadID = nil
    selectedThread = nil
  }

  func reconcileTaskSelection() {
    guard let selectedTaskID else { return }
    guard tasks.contains(where: { $0.taskID == selectedTaskID }) else {
      if conversation?.taskID == selectedTaskID {
        closeConversation()
      }
      self.selectedTaskID = nil
      return
    }
  }

  func updateChatBrowserVisibility() {
    cancelChatBrowserSleep()
    guard isChatBrowserEnabled, selection != .workbench, chatWebView != nil else { return }
    let delay = chatBrowserSleepDelay
    chatWebViewSleepTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self,
        self.selection != .workbench,
        self.isChatBrowserEnabled
      else { return }
      self.chatWebViewSleepTask = nil
      self.releaseChatWebView()
    }
  }

  func cancelChatBrowserSleep() {
    chatWebViewSleepTask?.cancel()
    chatWebViewSleepTask = nil
  }

  func releaseChatWebView() {
    if let url = chatWebView?.url,
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "chatgpt.com"
    {
      chatBrowserResumeURL = url
    }
    chatWebView?.stopLoading()
    chatWebView?.navigationDelegate = nil
    chatWebView?.uiDelegate = nil
    chatWebView = nil
  }

  func currentClient() throws -> any BridgeServiceClientProtocol {
    guard let client, connectionState == .connected else {
      throw BridgeServiceClientError.unavailable
    }
    return client
  }

  func runMutation(
    _ operation:
      @escaping @MainActor @Sendable (any BridgeServiceClientProtocol) async throws
      -> Void
  ) {
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        try await operation(try self.currentClient())
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }

  func updateExposureState(_ mode: MCPServiceExposureMode) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: mode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: serviceStatus.workbenchProjectID
    )
  }

  func updateWorkbenchProjectState(_ projectID: String?) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: serviceStatus.exposureMode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: projectID
    )
  }

  static func message(_ error: any Error) -> String {
    if case .remoteError(let remote) = error as? BridgeServiceIPCCodecError {
      return remote.message
    }
    if let codec = error as? BridgeServiceIPCCodecError {
      switch codec {
      case .requestMismatch:
        return "后台 Service 与本 App 的 IPC 版本不一致，请重新注册或重启后台 Service。"
      case .unsupportedSchemaVersion:
        return "后台 Service 与本 App 的 IPC 版本不一致，请重新注册或重启后台 Service。"
      default:
        break
      }
    }
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return error.localizedDescription
  }

  private func closeClient() async {
    let current = client
    client = nil
    await current?.close()
  }

  private func startPolling() {
    guard let pollInterval, pollingTask == nil else { return }
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          return
        }
        guard let self, !self.stopped else { return }
        await self.refresh(silent: true, includeCatalog: false)
      }
    }
  }

  private func threadCatalogRefreshDue(now: Date = Date()) -> Bool {
    guard let lastThreadCatalogRefreshAt else { return true }
    return
      now.timeIntervalSince(lastThreadCatalogRefreshAt) >= threadCatalogRefreshInterval
  }

  private func reconcileProjectSelection() {
    guard let selectedProjectID,
      !projects.contains(where: { $0.projectID == selectedProjectID })
    else { return }
    self.selectedProjectID = nil
    selectedTaskID = nil
    threads = []
    selectedThread = nil
  }

  private static func taskCatalogChanged(
    from previous: [MCPServiceTaskSnapshot],
    to current: [MCPServiceTaskSnapshot]
  ) -> Bool {
    taskCatalogSignature(previous) != taskCatalogSignature(current)
  }

  private static func taskCatalogSignature(
    _ values: [MCPServiceTaskSnapshot]
  ) -> [TaskCatalogKey] {
    values
      .map {
        TaskCatalogKey(
          taskID: $0.taskID,
          projectID: $0.projectID,
          status: $0.status,
          threadID: $0.threadID
        )
      }
      .sorted { $0.taskID < $1.taskID }
  }
}

private struct TaskCatalogKey: Equatable {
  let taskID: String
  let projectID: String
  let status: String
  let threadID: String?
}

private func optional<Value: Sendable>(
  _ operation: @escaping @Sendable () async throws -> Value
) async -> Value? {
  try? await operation()
}
