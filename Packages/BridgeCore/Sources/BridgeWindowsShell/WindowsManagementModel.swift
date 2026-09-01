#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  @MainActor
  final class WindowsManagementModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: ManagementDisplayBox

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var projects: [MCPProjectSummary] = []
    private(set) var agentProviders: [IPCAgentProviderSummary] = []
    private(set) var agentInstallations: [IPCAgentInstallationSummary] = []
    var selectedProjectID: String?
    var selectedProviderID: String?
    var selectedInstallationID: String?
    private var projectLoading = false
    private var agentLoading = false
    var projectBusy = false
    var agentBusy = false
    private var projectStatusText = "尚未加载项目。"
    private var agentStatusText = "尚未加载 Agent 目录。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      let emptyProject = WindowsProjectManagementDisplay(
        rows: [],
        selectedIndex: nil,
        detailText: "请选择项目。",
        policy: nil,
        registerEnabled: false,
        removeEnabled: false,
        savePolicyEnabled: false,
        statusText: "尚未加载项目。"
      )
      let emptyAgent = WindowsAgentManagementDisplay(
        providerRows: [],
        providerIDs: [],
        selectedProviderIndex: nil,
        providerDetailText: "暂无 Provider。",
        providerRequiresConfiguration: false,
        installationRows: [],
        selectedInstallationIndex: nil,
        installationDetailText: "请选择安装记录。",
        registerEnabled: false,
        enableEnabled: false,
        disableEnabled: false,
        reprobeEnabled: false,
        acceptReplacementEnabled: false,
        removeEnabled: false,
        statusText: "尚未加载 Agent 目录。"
      )
      displayBox = ManagementDisplayBox(
        value: WindowsManagementDisplay(
          connectionState: .idle,
          availableAgentCount: 0,
          project: emptyProject,
          agent: emptyAgent
        )
      )
    }

    func refresh() async {
      guard !projectLoading, !agentLoading else { return }
      projectStatusText = "正在检查后台 Service…"
      agentStatusText = "正在检查后台 Service…"
      publishDisplay()
      do {
        _ = try await client.status()
        connectionState = .connected
      } catch {
        connectionState = .unavailable
        let message = BridgeServiceErrorMessage.message(error)
        projectStatusText = "项目读取失败：\(message)"
        agentStatusText = "Agent 目录读取失败：\(message)"
        publishDisplay()
        return
      }
      await refreshProjects()
      await refreshAgents()
    }

    func refreshProjects() async {
      guard !projectLoading else { return }
      projectLoading = true
      publishDisplay()
      do {
        projects = try await client.projects()
        connectionState = .connected
        reconcileProjectSelection()
        projectStatusText = "已加载 \(projects.count) 个项目。"
      } catch {
        projectStatusText = "项目读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      projectLoading = false
      publishDisplay()
    }

    func refreshAgents() async {
      guard !agentLoading else { return }
      agentLoading = true
      publishDisplay()
      do {
        let catalog = try await client.agentCatalog()
        connectionState = .connected
        agentProviders = catalog.providers
        agentInstallations = catalog.installations
        reconcileAgentSelection()
        agentStatusText = "已加载 \(agentInstallations.count) 条安装记录。"
      } catch {
        agentStatusText = "Agent 目录读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      agentLoading = false
      publishDisplay()
    }

    func selectProject(at index: Int) {
      guard projects.indices.contains(index) else { return }
      selectedProjectID = projects[index].projectID
      projectStatusText = "已选择项目：\(projects[index].name)"
      publishDisplay()
    }

    func selectProvider(at index: Int) {
      guard agentProviders.indices.contains(index) else { return }
      selectedProviderID = agentProviders[index].providerID
      agentStatusText = "已选择 Provider：\(agentProviders[index].displayName)"
      publishDisplay()
    }

    func selectInstallation(at index: Int) {
      guard agentInstallations.indices.contains(index) else { return }
      selectedInstallationID = agentInstallations[index].installationID
      agentStatusText = "已选择安装：\(agentInstallations[index].displayName)"
      publishDisplay()
    }

    func refreshDisplaySnapshot() {
      publishDisplay()
    }

    func publishDisplay() {
      let projectItems = projects.map(ProjectAgentPresentation.project)
      let selectedProjectIndex = selectedProjectID.flatMap { id in
        projects.firstIndex { $0.projectID == id }
      }
      let selectedProject = selectedProjectIndex.flatMap { projectItems[$0] }
      let providerItems = agentProviders.map(ProjectAgentPresentation.provider)
      let selectedProviderIndex = selectedProviderID.flatMap { id in
        agentProviders.firstIndex { $0.providerID == id }
      }
      let selectedProvider = selectedProviderIndex.flatMap { providerItems[$0] }
      let installationItems = agentInstallations.map { installation in
        let providerName = agentProviders.first { $0.providerID == installation.providerID }?
          .displayName
        return ProjectAgentPresentation.installation(installation, providerName: providerName)
      }
      let selectedInstallationIndex = selectedInstallationID.flatMap { id in
        agentInstallations.firstIndex { $0.installationID == id }
      }
      let selectedInstallation = selectedInstallationIndex.flatMap { installationItems[$0] }
      let connected = connectionState == .connected
      let projectActions = connected && !projectBusy && !projectLoading
      let agentActions = connected && !agentBusy && !agentLoading
      let selectedAgent = selectedInstallationIndex.flatMap { agentInstallations[$0] }
      let canEnable =
        selectedAgent.map {
          !$0.isEnabled && $0.availability == "available"
        } ?? false
      let canDisable = selectedAgent?.isEnabled ?? false
      let projectDisplay = WindowsProjectManagementDisplay(
        rows: projectItems.map(\.rowText),
        selectedIndex: selectedProjectIndex,
        detailText: selectedProject?.detailText ?? "请选择项目。",
        policy: selectedProject.map {
          WindowsProjectPolicy(
            read: $0.readPermission,
            write: $0.writePermission,
            network: $0.networkPermission
          )
        },
        registerEnabled: projectActions,
        removeEnabled: projectActions && selectedProject != nil,
        savePolicyEnabled: projectActions && selectedProject != nil,
        statusText: projectStatusText
      )
      let agentDisplay = WindowsAgentManagementDisplay(
        providerRows: providerItems.map(\.rowText),
        providerIDs: providerItems.map(\.id),
        selectedProviderIndex: selectedProviderIndex,
        providerDetailText: selectedProvider?.detailText ?? "请选择 Provider。",
        providerRequiresConfiguration: selectedProvider?.requiresConfiguration ?? false,
        installationRows: installationItems.map(\.rowText),
        selectedInstallationIndex: selectedInstallationIndex,
        installationDetailText: selectedInstallation?.detailText ?? "请选择安装记录。",
        registerEnabled: agentActions && selectedProvider != nil,
        enableEnabled: agentActions && canEnable,
        disableEnabled: agentActions && canDisable,
        reprobeEnabled: agentActions && selectedAgent != nil,
        acceptReplacementEnabled: agentActions && selectedAgent?.availability == "needs_review",
        removeEnabled: agentActions && selectedAgent != nil,
        statusText: agentStatusText
      )
      displayBox.store(
        WindowsManagementDisplay(
          connectionState: connectionState,
          availableAgentCount: agentInstallations.filter {
            $0.isEnabled && $0.availability == "available"
          }.count,
          project: projectDisplay,
          agent: agentDisplay
        )
      )
    }

    private func reconcileProjectSelection() {
      guard let selectedProjectID else {
        self.selectedProjectID = projects.first?.projectID
        return
      }
      if !projects.contains(where: { $0.projectID == selectedProjectID }) {
        self.selectedProjectID = projects.first?.projectID
      }
    }

    private func reconcileAgentSelection() {
      if let selectedProviderID,
        !agentProviders.contains(where: { $0.providerID == selectedProviderID })
      {
        self.selectedProviderID = nil
      }
      if self.selectedProviderID == nil {
        self.selectedProviderID = agentProviders.first?.providerID
      }
      if let selectedInstallationID,
        !agentInstallations.contains(where: { $0.installationID == selectedInstallationID })
      {
        self.selectedInstallationID = nil
      }
      if self.selectedInstallationID == nil {
        self.selectedInstallationID = agentInstallations.first?.installationID
      }
    }

    func setProjectBusy(_ value: Bool) {
      projectBusy = value
      publishDisplay()
    }

    func setAgentBusy(_ value: Bool) {
      agentBusy = value
      publishDisplay()
    }

    func setProjectStatus(_ value: String) {
      projectStatusText = value
      publishDisplay()
    }

    func setAgentStatus(_ value: String) {
      agentStatusText = value
      publishDisplay()
    }
  }
#endif
