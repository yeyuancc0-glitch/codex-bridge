import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
  func saveCustomInstructions(_ instructions: String) {
    guard !isSavingCustomInstructions else { return }
    isSavingCustomInstructions = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isSavingCustomInstructions = false }
      do {
        try await self.currentClient().setCustomInstructions(instructions)
        self.customInstructions = instructions
        self.postToast("全局自定义指令已保存；Qwen 重连后应用，ChatGPT 请刷新插件并在新对话中重新添加")
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }

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
      self.postToast("已成功注册项目：\(url.lastPathComponent)")
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
      self.postToast("项目权限配置已保存生效")
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

  private func loadSkills(projectID: String) {
    guard let client, connectionState == .connected else { return }
    Task { [weak self] in
      do {
        let result = try await client.skills(projectID: projectID)
        guard self?.selectedProjectID == projectID else { return }
        self?.skills = result.skills
      } catch {
        self?.skills = []
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
      self.postToast("Direct 命令配置已保存生效")
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
      self.postToast("Direct 命令模式已保存")
    }
  }

  public func removeProject(_ projectID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.removeProject(projectID: projectID)
      if self.selectedProjectID == projectID {
        self.selectProject(nil)
        self.threads = []
        self.skills = []
        self.selectedThread = nil
      }
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已移除项目")
    }
  }

  public func selectProject(_ projectID: String?) {
    if selectedProjectID != projectID {
      closeConversation()
    }
    selectedProjectID = projectID
    persistWorkbenchProjectSelection(projectID)
    selectedTaskID = nil
    selectedThread = nil
    selectedThreadID = nil
    threads = []
    guard let projectID else { return }
    loadProjectDetail(projectID: projectID)
    loadSkills(projectID: projectID)
    Task { [weak self] in
      await self?.loadThreads(projectID: projectID)
    }
  }

  func persistWorkbenchProjectSelection(_ projectID: String?) {
    let precedingTask = workbenchProjectSyncTask
    workbenchProjectSyncTask = Task { [weak self] in
      await precedingTask?.value
      guard let self, self.selectedProjectID == projectID else { return }
      do {
        let client = try self.currentClient()
        try await client.setWorkbenchProject(projectID: projectID)
        guard self.selectedProjectID == projectID else { return }
        self.updateWorkbenchProjectState(projectID)
      } catch {
        guard self.selectedProjectID == projectID else { return }
        self.errorMessage = Self.message(error)
      }
    }
  }

  public func openThread(_ threadID: String, inProject projectID: String? = nil) {
    openThread(threadID, inProject: projectID, preferredTaskID: nil)
  }

  private func openThread(
    _ threadID: String,
    inProject projectID: String?,
    preferredTaskID: String?
  ) {
    let targetProjectID =
      projectID ?? selectedProjectID
      ?? tasks.first(where: { $0.threadID == threadID })?.projectID
      ?? projects.first?.projectID
    guard let targetProjectID else { return }

    if selectedProjectID != targetProjectID {
      selectedProjectID = targetProjectID
      persistWorkbenchProjectSelection(targetProjectID)
    }
    selectedThreadID = threadID

    let relatedTask = tasks.first(where: {
      $0.threadID == threadID && $0.isCodexTask
        && (preferredTaskID == nil || $0.taskID == preferredTaskID)
    })
    selectedTaskID = relatedTask?.taskID

    if let preferredTaskID {
      if relatedTask?.isActive == true {
        openConversation(taskID: preferredTaskID)
      } else {
        closeConversation()
      }
    } else if let activeTask = tasks.first(where: {
      $0.threadID == threadID && $0.isCodexTask && $0.isRunning
    }) {
      openConversation(taskID: activeTask.taskID)
    } else {
      closeConversation()
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

  public func openTask(_ taskID: String) {
    guard let task = tasks.first(where: { $0.taskID == taskID }) else { return }

    if selectedProjectID != task.projectID {
      selectProject(task.projectID)
    }
    selectedTaskID = task.taskID
    selectedThread = nil
    selectedThreadID = task.isCodexTask ? task.threadID : nil

    if task.isCodexTask, let threadID = task.threadID {
      openThread(threadID, inProject: task.projectID, preferredTaskID: task.taskID)
    } else {
      openConversation(taskID: task.taskID)
    }
  }

  public func stopTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.stopTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func interruptTask(_ task: MCPServiceTaskSnapshot) {
    guard let expectedTurnID = task.expectedControlID else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.interruptTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func steerTask(_ task: MCPServiceTaskSnapshot, input: String) {
    guard let expectedTurnID = task.expectedControlID,
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes,
      !input.contains("\0")
    else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.steerTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID,
        input: input
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func openConversation(taskID: String) {
    guard let client, connectionState == .connected else {
      errorMessage = "后台 Service 未连接，无法查看对话。"
      return
    }
    if let task = tasks.first(where: { $0.taskID == taskID }) {
      selectedTaskID = task.taskID
      if task.isExternalAgentTask {
        selectedThread = nil
        selectedThreadID = nil
      }
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
      self.postToast("已删除任务记录")
    }
  }

  public func resolveApproval(_ approval: IPCApprovalSummary, decision: String) {
    let resolutionKey = WorkbenchApprovalResolutionKey.task(approval.approvalID)
    guard resolvingApprovalKeys.insert(resolutionKey).inserted else { return }
    errorMessage = nil
    let providerName =
      tasks.first(where: { $0.taskID == approval.taskID })?.providerDisplayName
      ?? "Codex"
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try self.currentClient()
        try await client.resolveApproval(
          IPCApprovalResolutionRequest(
            taskID: approval.taskID,
            approvalID: approval.approvalID,
            decision: decision
          )
        )
        self.completeTaskApprovalResolution(
          approval,
          decision: decision,
          providerName: providerName
        )
        await self.refresh(silent: true, includeCatalog: false)
      } catch {
        let pending = try? await self.currentClient().approvals(taskID: approval.taskID)
        if let pending {
          self.applyApprovalSnapshot(pending)
        }
        if pending?.contains(where: { $0.approvalID == approval.approvalID }) != false {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = Self.message(error)
        } else {
          self.completeTaskApprovalResolution(
            approval,
            decision: decision,
            providerName: providerName
          )
        }
      }
    }
  }

  public func resolveDirectApproval(
    _ approval: IPCPendingDirectApproval,
    allow: Bool
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.direct(approval.approvalID)
    guard resolvingApprovalKeys.insert(resolutionKey).inserted else { return }
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try self.currentClient()
        let accepted: Bool
        if allow {
          accepted = try await client.approveDirectApproval(approvalID: approval.approvalID)
        } else {
          accepted = try await client.denyDirectApproval(approvalID: approval.approvalID)
        }
        guard accepted else {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = "Direct 审批已失效或已被处理，请刷新状态。"
          return
        }
        self.completeDirectApprovalResolution(approval, allow: allow)
        await self.refresh(silent: true, includeCatalog: false)
      } catch {
        let pending = try? await self.currentClient().pendingDirectApprovals()
        if let pending {
          self.applyDirectApprovalSnapshot(pending)
        }
        if pending?.contains(where: { $0.approvalID == approval.approvalID }) != false {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = Self.message(error)
        } else {
          self.completeDirectApprovalResolution(approval, allow: allow)
        }
      }
    }
  }

  private func completeTaskApprovalResolution(
    _ approval: IPCApprovalSummary,
    decision: String,
    providerName: String
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.task(approval.approvalID)
    resolvingApprovalKeys.remove(resolutionKey)
    resolvedTaskApprovalKeys.insert(resolutionKey)
    approvals.removeAll { $0.approvalID == approval.approvalID }
    postToast(
      decision == "deny" ? "已拒绝 \(providerName) 操作" : "已批准 \(providerName) 操作",
      symbol: decision == "deny" ? "xmark.shield.fill" : "checkmark.shield.fill",
      tone: decision == "deny" ? .warning : .success
    )
  }

  private func completeDirectApprovalResolution(
    _ approval: IPCPendingDirectApproval,
    allow: Bool
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.direct(approval.approvalID)
    resolvingApprovalKeys.remove(resolutionKey)
    resolvedDirectApprovalKeys.insert(resolutionKey)
    directApprovals.removeAll { $0.approvalID == approval.approvalID }
    postToast(
      allow ? "已批准 Direct 操作" : "已拒绝 Direct 操作",
      symbol: allow ? "checkmark.shield.fill" : "xmark.shield.fill",
      tone: allow ? .success : .warning
    )
  }

  func isResolvingApproval(_ approval: IPCApprovalSummary) -> Bool {
    resolvingApprovalKeys.contains(WorkbenchApprovalResolutionKey.task(approval.approvalID))
  }

  func isResolvingDirectApproval(_ approval: IPCPendingDirectApproval) -> Bool {
    resolvingApprovalKeys.contains(WorkbenchApprovalResolutionKey.direct(approval.approvalID))
  }

  public func setDirectApprovalMode(_ mode: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setDirectApprovalMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast(mode == "auto" ? "已开启 Direct 操作自动批准" : "已设置为每次 Direct 操作均需批准")
    }
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) {
    updateExposureState(mode)
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setExposureMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("MCP 工具权限已更新为：\(mode.localizedTitle)")
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
        self.postToast("模型偏好设置已更新")
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
      self.postToast("Secure Tunnel 配置已提交，正在启动连接…")
    }
  }

  public func connectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.connectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("正在连接 Secure Tunnel…")
    }
  }

  public func disconnectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.disconnectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("Secure Tunnel 已断开连接", symbol: "link.badge.plus", tone: .neutral)
    }
  }

  public func clearTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.clearTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已清除 Secure Tunnel 配置", symbol: "trash", tone: .neutral)
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
      reconcileThreadSelection()
    } catch {
      guard selectedProjectID == projectID else { return }
      threads = []
    }
  }
}
