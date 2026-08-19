import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
  public func registerProject(at url: URL) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.registerProject(
        IPCProjectRegistrationRequest(
          name: url.lastPathComponent,
          absolutePath: url.standardizedFileURL.path
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func updateProjectPolicy(
    projectID: String,
    draft: BridgeProjectPolicyDraft
  ) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.updateProjectPolicy(
        IPCProjectPolicyRequest(
          projectID: projectID,
          readPermission: draft.readPermission,
          writePermission: draft.writePermission,
          networkPermission: draft.networkPermission
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func loadProjectDetail(projectID: String) {
    guard let client, connectionState == .connected else { return }
    Task { [weak self] in
      do {
        let detail = try await client.projectCommands(projectID: projectID)
        self?.projectDetails[projectID] = detail
      } catch {
        self?.errorMessage = "读取项目命令配置失败。"
      }
    }
  }

  func saveProjectCommands(
    projectID: String,
    drafts: [BridgeWorkspaceCommandDraft],
    commandBlacklist: [IPCBlacklistRule] = []
  ) {
    runMutation { [weak self] client in
      guard let self else { return }
      let commands = drafts.map { $0.toIPCCommand() }
      let detail = try await client.updateProjectCommands(
        projectID: projectID,
        commands: commands,
        commandBlacklist: commandBlacklist
      )
      self.projectDetails[projectID] = detail
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func setProjectCommandMode(projectID: String, mode: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      let detail = try await client.setProjectCommandMode(
        projectID: projectID,
        commandMode: mode
      )
      self.projectDetails[projectID] = detail
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func removeProject(_ projectID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.removeProject(projectID: projectID)
      if self.selectedProjectID == projectID {
        self.selectedProjectID = nil
        self.threads = []
        self.selectedThread = nil
      }
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func selectProject(_ projectID: String?) {
    selectedProjectID = projectID
    selectedThread = nil
    selectedThreadID = nil
    threads = []
    guard let projectID else { return }
    loadProjectDetail(projectID: projectID)
    Task { [weak self] in
      await self?.loadThreads(projectID: projectID)
    }
  }

  public func openThread(_ threadID: String, inProject projectID: String? = nil) {
    let targetProjectID =
      projectID ?? selectedProjectID
      ?? tasks.first(where: { $0.threadID == threadID })?.projectID
      ?? projects.first?.projectID
    guard let targetProjectID else { return }

    if selectedProjectID != targetProjectID {
      selectedProjectID = targetProjectID
    }
    selectedThreadID = threadID

    // Check if there is an active task on this thread to stream live conversation
    if let activeTask = tasks.first(where: { $0.threadID == threadID && $0.isRunning }) {
      openConversation(taskID: activeTask.taskID)
    }

    runMutation { [weak self] client in
      guard let self else { return }
      let page = try await client.readThread(
        IPCThreadReadRequest(
          projectID: targetProjectID,
          threadID: threadID,
          detail: .full,
          limit: 100
        )
      )
      guard self.selectedThreadID == threadID else { return }
      self.selectedThread = page
    }
  }

  public func stopTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.stopTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func openConversation(taskID: String) {
    guard let client, connectionState == .connected else {
      errorMessage = "后台 Service 未连接，无法查看对话。"
      return
    }
    closeConversation()
    let conversation = TaskConversationModel(taskID: taskID, client: client)
    self.conversation = conversation
    Task {
      await conversation.start()
    }
  }

  public func closeConversation() {
    guard let conversation else { return }
    let taskID = conversation.taskID
    let subscriptionID = conversation.subscriptionID
    self.conversation = nil
    conversation.cancel()
    guard subscriptionID >= 0, let client, connectionState == .connected else { return }
    Task {
      try? await client.unsubscribeTaskConversation(
        taskID: taskID,
        subscriptionID: subscriptionID
      )
    }
  }

  public func deleteTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.deleteTask(taskID: taskID)
      if self.conversation?.taskID == taskID {
        self.closeConversation()
      }
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func resolveApproval(_ approval: IPCApprovalSummary, allow: Bool) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.resolveApproval(
        IPCApprovalResolutionRequest(
          taskID: approval.taskID,
          approvalID: approval.approvalID,
          decision: allow ? "allow" : "deny"
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func resolveDirectApproval(
    _ approval: IPCPendingDirectApproval,
    allow: Bool
  ) {
    runMutation { [weak self] client in
      guard let self else { return }
      if allow {
        _ = try await client.approveDirectApproval(approvalID: approval.approvalID)
      } else {
        _ = try await client.denyDirectApproval(approvalID: approval.approvalID)
      }
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func setDirectApprovalMode(_ mode: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setDirectApprovalMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) {
    updateExposureState(mode)
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setExposureMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func setModelPreferences(_ preferences: IPCModelPreferences) {
    let previous = modelPreferences
    modelPreferences = preferences
    runMutation { [weak self] client in
      guard let self else { return }
      do {
        try await client.setModelPreferences(preferences)
        await self.refresh(silent: true, includeCatalog: true)
      } catch {
        modelPreferences = previous
        throw error
      }
    }
  }

  func setSupervisorEnabled(_ enabled: Bool) {
    guard let current = modelPreferences else { return }
    let previous = modelPreferences
    modelPreferences = IPCModelPreferences(
      executionModel: current.executionModel,
      executionEffort: current.executionEffort,
      supervisorModel: current.supervisorModel,
      supervisorEffort: current.supervisorEffort,
      supervisorEnabled: enabled,
      accessMode: current.accessMode,
      fastModeEnabled: current.fastModeEnabled
    )
    runMutation { [weak self] client in
      guard let self else { return }
      do {
        try await client.setSupervisorEnabled(enabled)
        await self.refresh(silent: true, includeCatalog: true)
      } catch {
        modelPreferences = previous
        throw error
      }
    }
  }

  func setExecutionModel(_ modelID: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == modelID })
    else { return }

    let effort =
      model.reasoningEfforts.contains(current.executionEffort)
      ? current.executionEffort
      : model.defaultReasoningEffort ?? model.reasoningEfforts[0]

    setModelPreferences(
      IPCModelPreferences(
        executionModel: modelID,
        executionEffort: effort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setExecutionEffort(_ effort: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == current.executionModel }),
      model.reasoningEfforts.contains(effort)
    else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: effort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setAccessMode(_ mode: String) {
    guard let current = modelPreferences else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: mode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setFastMode(_ enabled: Bool) {
    guard let current = modelPreferences else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: enabled
      )
    )
  }

  func setSupervisorModel(_ modelID: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == modelID })
    else { return }

    let effort =
      model.reasoningEfforts.contains(current.supervisorEffort)
      ? current.supervisorEffort
      : model.defaultReasoningEffort ?? model.reasoningEfforts[0]

    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: modelID,
        supervisorEffort: effort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setSupervisorEffort(_ effort: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == current.supervisorModel }),
      model.reasoningEfforts.contains(effort)
    else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: effort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  public func configureTunnel(tunnelID: String, runtimeKey: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.configureTunnel(
        IPCTunnelConfigurationRequest(
          tunnelID: tunnelID,
          runtimeKey: runtimeKey
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func connectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.connectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func disconnectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.disconnectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func clearTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.clearTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func loadThreads(projectID: String) async {
    do {
      let client = try currentClient()
      lastThreadCatalogRefreshAt = Date()
      let page = try await client.threads(
        IPCThreadListRequest(projectID: projectID, limit: 100)
      )
      guard selectedProjectID == projectID else { return }
      threads = page.threads
    } catch {
      guard selectedProjectID == projectID else { return }
      threads = []
      errorMessage = Self.message(error)
    }
  }
}
