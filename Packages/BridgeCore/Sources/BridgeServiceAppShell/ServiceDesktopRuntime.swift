import BridgeIPC
import BridgeMCP
import Foundation
import WebKit
import BridgeServiceAppCore

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

  public func shutdownForApplicationTermination() async {
    if !keepServiceRunningAfterAppExit {
      await disableBackgroundService()
    }
    await shutdownUI()
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
      agentModelOptions = []
      agentModelOptionsByProvider = [:]
      agentModelRefreshingProviders = []
      agentModelHydratingProviders = []
      agentModelRefreshErrorsByProvider = [:]
      agentModelCatalogGenerations = [:]
      agentModelCatalogScopes = [:]
      agentModelHydrationGenerations = [:]
      agentModelRefreshGenerations = [:]
      agentModelHydrationSuppressions = [:]
      agentModelDefaultLoadGenerations = [:]
      agentModelDefaultRevisions = [:]
      for task in agentModelDefaultMutationTasks.values {
        task.cancel()
      }
      agentModelDefaultMutationTasks = [:]
      agentModelDefaults = [:]
      openCodeDefaultModel = nil
      openCodeDefaultPermissionMode = "build"
      openCodeDefaultEffort = nil
      isRefreshingAgentModels = false
      agentModelRefreshError = nil
      isManagingAgents = false
      tasks = []
      approvals = []
      taskStartApprovalMode = "require"
      workbenchPermissionMode = "workspace-write"
      confirmedWorkbenchPermissionMode = "workspace-write"
      resolvingApprovalKeys = []
      resolvedTaskApprovalKeys = []
      resolvedDirectApprovalKeys = []
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
      conversationPresentationCache.removeAll()
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
    guard !stopped else { return }
    if refreshInProgress {
      pendingRefresh = true
      pendingVisibleRefresh = pendingVisibleRefresh || !silent
      pendingCatalogRefresh = pendingCatalogRefresh || includeCatalog
      return
    }
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

    refreshInProgress = true
    if !silent { isRefreshing = true }
    do {
      let refreshedStatus = try await client.status()
      if serviceStatus != refreshedStatus { serviceStatus = refreshedStatus }
      applyWorkbenchPermissionMode(refreshedStatus.workbenchPermissionMode)
      if connectionState != .connected { connectionState = .connected }
      if !silent { lastRefreshAt = Date() }
      if !silent { errorMessage = nil }
      await refreshCollections(
        client: client,
        includeCatalog: includeCatalog,
        includeThreads: !silent
      )
    } catch {
      await closeClient()
      if connectionState != .unavailable { connectionState = .unavailable }
      if !silent { errorMessage = Self.message(error) }
    }
    refreshInProgress = false
    if !silent { isRefreshing = false }
    await runPendingRefreshIfNeeded()
  }

  private func runPendingRefreshIfNeeded() async {
    guard pendingRefresh, !stopped else { return }
    let visible = pendingVisibleRefresh
    let includeCatalog = pendingCatalogRefresh
    pendingRefresh = false
    pendingVisibleRefresh = false
    pendingCatalogRefresh = false
    await refresh(silent: !visible, includeCatalog: includeCatalog)
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
        let status = try await candidate.status()
        serviceStatus = status
        applyWorkbenchPermissionMode(status.workbenchPermissionMode)
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

  func applyApprovalSnapshot(_ value: [IPCApprovalSummary]) {
    let incomingKeys = Set(value.map { WorkbenchApprovalResolutionKey.task($0.approvalID) })
    if resolvedTaskApprovalKeys.count > 512 {
      resolvedTaskApprovalKeys.formIntersection(incomingKeys)
    }
    let hiddenKeys = resolvingApprovalKeys.union(resolvedTaskApprovalKeys)
    let visible = value.filter {
      !hiddenKeys.contains(WorkbenchApprovalResolutionKey.task($0.approvalID))
    }
    if approvals != visible { approvals = visible }
  }

  func applyDirectApprovalSnapshot(_ value: [IPCPendingDirectApproval]) {
    let incomingKeys = Set(value.map { WorkbenchApprovalResolutionKey.direct($0.approvalID) })
    if resolvedDirectApprovalKeys.count > 512 {
      resolvedDirectApprovalKeys.formIntersection(incomingKeys)
    }
    let hiddenKeys = resolvingApprovalKeys.union(resolvedDirectApprovalKeys)
    let visible = value.filter {
      !hiddenKeys.contains(WorkbenchApprovalResolutionKey.direct($0.approvalID))
    }
    if directApprovals != visible { directApprovals = visible }
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

  func reloadChatBrowser() {
    guard isChatBrowserEnabled else { return }
    cancelChatBrowserSleep()
    chatBrowserReloadRequest &+= 1
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
      workbenchProjectID: serviceStatus.workbenchProjectID,
      workbenchPermissionMode: serviceStatus.workbenchPermissionMode
    )
  }

  func updateWorkbenchProjectState(_ projectID: String?) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: serviceStatus.exposureMode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: projectID,
      workbenchPermissionMode: serviceStatus.workbenchPermissionMode
    )
  }

  func updateWorkbenchPermissionModeState(_ mode: String) {
    guard let serviceStatus else { return }
    self.serviceStatus = IPCServiceStatusResponse(
      status: serviceStatus.status,
      localMCPURL: serviceStatus.localMCPURL,
      exposureMode: serviceStatus.exposureMode,
      tunnel: serviceStatus.tunnel,
      workbenchProjectID: serviceStatus.workbenchProjectID,
      workbenchPermissionMode: mode
    )
  }

  func applyWorkbenchPermissionMode(_ mode: String?) {
    guard workbenchPermissionModeSyncTask == nil else { return }
    guard let mode, mode == "read-only" || mode == "workspace-write" else {
      workbenchPermissionMode = "workspace-write"
      confirmedWorkbenchPermissionMode = "workspace-write"
      return
    }
    workbenchPermissionMode = mode
    confirmedWorkbenchPermissionMode = mode
  }

  static func message(_ error: any Error) -> String {
    BridgeServiceErrorMessage.message(error)
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
        guard let self, !self.stopped else { return }
        let delay = self.nextPollingDelay(base: pollInterval)
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard !self.stopped else { return }
        await self.refresh(silent: true, includeCatalog: false)
      }
    }
  }

  func nextPollingDelay(base: Duration) -> Duration {
    let needsLiveUpdates =
      tasks.contains(where: \.isActive) || !approvals.isEmpty || !directApprovals.isEmpty
      || !resolvingApprovalKeys.isEmpty
    return needsLiveUpdates ? base : max(base, idlePollInterval)
  }

}
