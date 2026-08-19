import BridgeIPC
import BridgeMCP
import Foundation

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
      tasks = []
      approvals = []
      models = []
      modelPreferences = nil
      modelCatalogError = nil
      threads = []
      selectedThread = nil
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
      await refreshCollections(client: client, includeCatalog: includeCatalog)
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
        await refreshCollections(client: candidate, includeCatalog: includeCatalog)
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
    includeCatalog: Bool
  ) async {
    async let projectResult = optional { try await client.projects() }
    async let taskResult = optional {
      try await client.tasks(IPCTaskListRequest(limit: 200))
    }
    async let approvalResult = optional { try await client.approvals(taskID: nil) }
    async let directApprovalResult = optional { try await client.pendingDirectApprovals() }
    async let directApprovalModeResult = optional { try await client.directApprovalMode() }

    if let value = await projectResult {
      projects = value
      reconcileProjectSelection()
      if selectedProjectID == nil, let first = value.first {
        selectedProjectID = first.projectID
      }
      if let activeProjectID = selectedProjectID {
        let threadPage = await optional {
          try await client.threads(IPCThreadListRequest(projectID: activeProjectID, limit: 100))
        }
        if let threadPage {
          threads = threadPage.threads
          if selectedThreadID == nil, let firstThread = threadPage.threads.first {
            openThread(firstThread.threadID, inProject: activeProjectID)
          }
        }
      }
    }
    if let value = await taskResult {
      tasks = value
      // If there's an active running task with a threadID, auto-switch to it if not set
      if let activeTask = value.first(where: \.isRunning), let threadID = activeTask.threadID {
        if selectedThreadID != threadID {
          openThread(threadID, inProject: activeTask.projectID)
        }
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
    }
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
      exposureMode: mode
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

  private func reconcileProjectSelection() {
    guard let selectedProjectID,
      !projects.contains(where: { $0.projectID == selectedProjectID })
    else { return }
    self.selectedProjectID = nil
    threads = []
    selectedThread = nil
  }
}

private func optional<Value: Sendable>(
  _ operation: @escaping @Sendable () async throws -> Value
) async -> Value? {
  try? await operation()
}
