#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension WindowsManagementModel {
    func registerProject(name: String, path: String) async {
      let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let absolutePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !projectName.isEmpty, !absolutePath.isEmpty else {
        setProjectStatus("项目名称和绝对路径不能为空。")
        return
      }
      guard connectionState == .connected else {
        setProjectStatus("后台 Service 未连接，无法注册项目。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在注册项目…")
      defer { setProjectBusy(false) }
      do {
        let detail = try await client.registerProject(
          IPCProjectRegistrationRequest(name: projectName, absolutePath: absolutePath)
        )
        selectedProjectID = detail.projectID
        await refreshProjects()
        setProjectStatus("项目已注册：\(detail.name)")
      } catch {
        setProjectStatus("项目注册失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func removeSelectedProject() async {
      guard let projectID = selectedProjectID,
        let project = projects.first(where: { $0.projectID == projectID })
      else {
        setProjectStatus("请先选择要移除的项目。")
        return
      }
      guard connectionState == .connected else {
        setProjectStatus("后台 Service 未连接，无法移除项目。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在移除项目…")
      defer { setProjectBusy(false) }
      do {
        try await client.removeProject(projectID: projectID)
        selectedProjectID = nil
        await refreshProjects()
        setProjectStatus("已移除项目：\(project.name)")
      } catch {
        setProjectStatus("项目移除失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func saveSelectedProjectPolicy(
      read: String,
      write: String,
      network: String
    ) async {
      guard let projectID = selectedProjectID else {
        setProjectStatus("请先选择要保存策略的项目。")
        return
      }
      guard connectionState == .connected else {
        setProjectStatus("后台 Service 未连接，无法保存项目策略。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在保存项目策略…")
      defer { setProjectBusy(false) }
      do {
        _ = try await client.updateProjectPolicy(
          IPCProjectPolicyRequest(
            projectID: projectID,
            readPermission: read,
            writePermission: write,
            networkPermission: network
          )
        )
        await refreshProjects()
        setProjectStatus("项目策略已保存生效。")
      } catch {
        setProjectStatus("项目策略保存失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func registerAgent(
      providerID: String,
      executablePath: String,
      configurationPath: String
    ) async {
      let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
      let configuration = configurationPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let provider = agentProviders.first(where: { $0.providerID == providerID }) else {
        setAgentStatus("请选择有效的 Provider。")
        return
      }
      guard !executable.isEmpty else {
        setAgentStatus("Agent 可执行文件路径不能为空。")
        return
      }
      guard !provider.requiresConfiguration || !configuration.isEmpty else {
        setAgentStatus("当前 Provider 需要配置文件路径。")
        return
      }
      guard connectionState == .connected else {
        setAgentStatus("后台 Service 未连接，无法登记 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus("正在登记并 Probe Agent…")
      defer { setAgentBusy(false) }
      do {
        let installation = try await client.registerAgentInstallation(
          IPCAgentRegistrationRequest(
            providerID: provider.providerID,
            displayName: provider.displayName,
            executablePath: executable,
            configurationPath: configuration.isEmpty ? nil : configuration
          )
        )
        selectedInstallationID = installation.installationID
        await refreshAgents()
        let state = ProjectAgentPresentation.availabilityLabel(installation.availability)
        setAgentStatus("Agent 已登记：\(installation.displayName)（\(state)）。")
      } catch {
        setAgentStatus("Agent 登记失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func setSelectedAgentEnabled(_ enabled: Bool) async {
      guard let installationID = selectedInstallationID,
        let installation = agentInstallations.first(where: { $0.installationID == installationID })
      else {
        setAgentStatus("请先选择要启停的 Agent 安装。")
        return
      }
      guard !enabled || installation.availability == "available" else {
        setAgentStatus("只有 Probe 可用的 Agent 才能启用。")
        return
      }
      guard connectionState == .connected else {
        setAgentStatus("后台 Service 未连接，无法更改 Agent 状态。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus(enabled ? "正在启用 Agent…" : "正在停用 Agent…")
      defer { setAgentBusy(false) }
      do {
        _ = try await client.setAgentInstallationEnabled(
          installationID: installationID,
          enabled: enabled
        )
        await refreshAgents()
        setAgentStatus(enabled ? "Agent 已启用。" : "Agent 已停用。")
      } catch {
        setAgentStatus("Agent 启停失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func reprobeSelectedAgent(acceptReplacement: Bool) async {
      guard let installationID = selectedInstallationID else {
        setAgentStatus("请先选择要 Probe 的 Agent 安装。")
        return
      }
      guard connectionState == .connected else {
        setAgentStatus("后台 Service 未连接，无法 Probe Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus(acceptReplacement ? "正在接受替换并 Probe…" : "正在 Probe Agent…")
      defer { setAgentBusy(false) }
      do {
        let installation = try await client.reprobeAgentInstallation(
          installationID: installationID,
          acceptReplacement: acceptReplacement
        )
        await refreshAgents()
        let state = ProjectAgentPresentation.availabilityLabel(installation.availability)
        setAgentStatus("Probe 完成：\(state)。")
      } catch {
        setAgentStatus("Agent Probe 失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func removeSelectedAgent() async {
      guard let installationID = selectedInstallationID else {
        setAgentStatus("请先选择要移除的 Agent 安装。")
        return
      }
      guard connectionState == .connected else {
        setAgentStatus("后台 Service 未连接，无法移除 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus("正在移除 Agent 登记…")
      defer { setAgentBusy(false) }
      do {
        try await client.removeAgentInstallation(installationID: installationID)
        selectedInstallationID = nil
        await refreshAgents()
        setAgentStatus("Agent 安装登记已移除。")
      } catch {
        setAgentStatus("Agent 移除失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }
  }
#endif
