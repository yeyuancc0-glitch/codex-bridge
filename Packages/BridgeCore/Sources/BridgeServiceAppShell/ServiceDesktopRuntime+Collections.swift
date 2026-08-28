import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
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
    async let taskStartApprovalModeResult = optional {
      try await client.taskStartApprovalMode()
    }
    async let mcpClientResult = optional { try await client.mcpClients() }

    if let value = await projectResult {
      applyProjectSnapshot(value)
    }

    if let value = await agentCatalogResult {
      applyAgentCatalogSnapshot(value)
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
      applyTaskSnapshot(value)
    }

    if shouldRefreshThreads, let projectID = selectedProjectID {
      await refreshThreadCollections(client: client, projectID: projectID)
    }

    if let value = await approvalResult {
      applyApprovalSnapshot(value)
    }
    if let value = await directApprovalResult {
      applyDirectApprovalSnapshot(value)
    }
    if let value = await directApprovalModeResult, directApprovalMode != value {
      directApprovalMode = value
    }
    if let value = await taskStartApprovalModeResult, taskStartApprovalMode != value {
      taskStartApprovalMode = value
    }
    if let value = await mcpClientResult, mcpClients != value {
      mcpClients = value
    }
    if includeCatalog {
      await refreshModelCatalog(client: client)
    }
  }

  private func applyProjectSnapshot(_ value: [MCPProjectSummary]) {
    guard projects != value else { return }
    projects = value
    reconcileProjectSelection()
    if selectedProjectID == nil {
      selectedProjectID =
        value.first(where: { $0.projectID == serviceStatus?.workbenchProjectID })?.projectID
        ?? value.first?.projectID
    }
  }

  private func applyAgentCatalogSnapshot(_ value: IPCAgentCatalogResponse) {
    if agentProviders != value.providers { agentProviders = value.providers }
    if agentInstallations != value.installations { agentInstallations = value.installations }
  }

  private func applyTaskSnapshot(_ value: [MCPServiceTaskSnapshot]) {
    if tasks != value {
      tasks = value
      reconcileTaskSelection()
    }
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

  private func refreshThreadCollections(
    client: any BridgeServiceClientProtocol,
    projectID: String
  ) async {
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

  private func refreshModelCatalog(client: any BridgeServiceClientProtocol) async {
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
