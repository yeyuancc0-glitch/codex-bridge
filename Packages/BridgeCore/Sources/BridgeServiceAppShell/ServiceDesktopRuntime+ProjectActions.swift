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
}
