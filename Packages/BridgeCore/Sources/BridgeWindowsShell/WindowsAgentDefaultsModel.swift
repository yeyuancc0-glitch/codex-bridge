#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore

  @MainActor
  final class WindowsAgentDefaultsModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsAgentDefaultsDisplay>

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var providers: [IPCAgentProviderSummary] = []
    private(set) var installations: [IPCAgentInstallationSummary] = []
    private(set) var models: [IPCAgentModelSummary] = []
    var selectedProviderID: String?
    var selectedInstallationID: String?
    var selectedModelID: String?
    var selectedEffort = ""
    var selectedPermissionMode: String = "build"
    private var busy = false
    private var statusText = "尚未加载 Agent 默认设置。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      displayBox = AuxiliaryDisplayBox(
        value: WindowsAgentDefaultsDisplay(
          connectionState: .idle,
          providerRows: [],
          selectedProviderIndex: nil,
          installationRows: [],
          selectedInstallationIndex: nil,
          installationDetailText: "请选择 Agent Provider 和安装记录。",
          modelRows: [],
          modelIDs: [],
          selectedModelIndex: nil,
          effortValues: [""],
          selectedEffortIndex: 0,
          permissionValues: Self.permissionValues(for: nil),
          selectedPermissionIndex: 0,
          refreshModelsEnabled: false,
          saveEnabled: false,
          statusText: statusText
        )
      )
    }

    static func permissionValues(for providerID: String?) -> [String] {
      guard let providerID else { return ["build", "plan"] }
      return AgentProviderPresentation.identifier(providerID) == "opencode"
        ? ["build", "plan"]
        : ["workspace-write", "read-only"]
    }

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取 Agent 目录…"
      publishDisplay()
      do {
        _ = try await client.status()
        connectionState = .connected
        let catalog = try await client.agentCatalog()
        providers = catalog.providers
        installations = catalog.installations
        reconcileSelection()
      } catch {
        statusText = "Agent 默认设置读取失败：\(BridgeServiceErrorMessage.message(error))"
        busy = false
        publishDisplay()
        return
      }
      busy = false
      await refreshModels()
    }

    func selectProvider(at index: Int) {
      guard providers.indices.contains(index) else { return }
      selectedProviderID = providers[index].providerID
      selectedInstallationID = availableInstallation(for: selectedProviderID)?.installationID
      models = []
      selectedModelID = nil
      reconcilePermissionMode()
      statusText = "已选择 Provider：\(providers[index].displayName)"
      publishDisplay()
    }

    func selectInstallation(at index: Int) {
      guard installations.indices.contains(index) else { return }
      let installation = installations[index]
      selectedInstallationID = installation.installationID
      selectedProviderID = installation.providerID
      models = []
      selectedModelID = nil
      reconcilePermissionMode()
      statusText = "已选择安装：\(installation.displayName)"
      publishDisplay()
    }

    func refreshModels() async {
      guard connectionState == .connected, let installation = availableInstallation() else {
        models = []
        selectedModelID = nil
        statusText = "没有可用且已启用的 Agent 安装。"
        publishDisplay()
        return
      }
      guard !busy else { return }
      busy = true
      statusText = "正在读取 Agent 模型…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let defaults = try await client.agentModelDefault(providerID: installation.providerID)
        let response = try await client.agentModels(
          installationID: installation.installationID,
          projectID: nil,
          modelID: nil,
          useStoredDefault: false
        )
        guard selectedProviderID == installation.providerID,
          selectedInstallationID == installation.installationID
        else { return }
        models = response.models
        selectedModelID = defaults.model
        if selectedModelID == nil {
          selectedModelID = models.first?.modelID
        }
        let permissionValues = Self.permissionValues(for: installation.providerID)
        selectedPermissionMode =
          permissionValues.contains(defaults.permissionMode)
          ? defaults.permissionMode
          : permissionValues[0]
        selectedEffort = defaults.effort ?? ""
        statusText = "已加载 \(models.count) 个模型，可保存 Provider 默认值。"
      } catch {
        statusText = "Agent 模型读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func saveDefaults(model: String, permissionMode: String, effort: String) async {
      guard let providerID = selectedProviderID, let installation = availableInstallation() else {
        statusText = "请选择可用的 Agent 安装。"
        publishDisplay()
        return
      }
      let permissionValues = Self.permissionValues(for: providerID)
      guard permissionValues.contains(permissionMode), availableEffortValues().contains(effort)
      else {
        statusText = "默认权限或推理强度无效。"
        publishDisplay()
        return
      }
      guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        statusText = "默认模型不能为空。"
        publishDisplay()
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存 Agent 默认设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        _ = try await client.setAgentDefaults(
          providerID: providerID,
          model: model,
          permissionMode: permissionMode,
          effort: effort.isEmpty ? nil : effort
        )
        selectedInstallationID = installation.installationID
        selectedModelID = model
        selectedPermissionMode = permissionMode
        selectedEffort = effort
        statusText = "Agent 默认设置已保存。"
      } catch {
        statusText = "Agent 默认设置保存失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func availableInstallation(for providerID: String? = nil)
      -> IPCAgentInstallationSummary?
    {
      let target = providerID ?? selectedProviderID
      if providerID == nil, let selectedInstallationID {
        return installations.first(where: {
          $0.installationID == selectedInstallationID
            && $0.isEnabled && $0.availability == "available" && $0.providerID == target
        })
      }
      return installations.first {
        $0.isEnabled && $0.availability == "available" && $0.providerID == target
      }
    }

    private func reconcileSelection() {
      if let selectedProviderID, providers.contains(where: { $0.providerID == selectedProviderID })
      {
        // Keep the user's provider selection.
      } else {
        selectedProviderID = providers.first?.providerID
      }
      if let selectedInstallationID,
        installations.contains(where: { $0.installationID == selectedInstallationID })
      {
        reconcilePermissionMode()
        return
      }
      selectedInstallationID = availableInstallation()?.installationID
      reconcilePermissionMode()
    }

    private func reconcilePermissionMode() {
      let values = Self.permissionValues(for: selectedProviderID)
      if !values.contains(selectedPermissionMode) {
        selectedPermissionMode = values[0]
      }
    }

    private func publishDisplay() {
      let providerIndex = selectedProviderID.flatMap { id in
        providers.firstIndex { $0.providerID == id }
      }
      let installationIndex = selectedInstallationID.flatMap { id in
        installations.firstIndex { $0.installationID == id }
      }
      let installation = installationIndex.flatMap { installations[$0] }
      let modelIndex = selectedModelID.flatMap { id in models.firstIndex { $0.modelID == id } }
      let effortValues = availableEffortValues()
      let effortIndex = effortValues.firstIndex(of: selectedEffort)
      let permissionValues = Self.permissionValues(for: selectedProviderID)
      let permissionIndex = permissionValues.firstIndex(of: selectedPermissionMode)
      let providerName = providerIndex.map { providers[$0].displayName } ?? "—"
      let detail =
        installation.map {
          [
            "Provider：\(providerName)",
            "安装：\($0.displayName)",
            "路径：\($0.executablePath)",
            "状态：\(ProjectAgentPresentation.availabilityLabel($0.availability))",
            "版本：\($0.version ?? "未知")",
          ].joined(separator: "\r\n")
        } ?? "请选择可用的 Agent 安装。"
      let value = WindowsAgentDefaultsDisplay(
        connectionState: connectionState,
        providerRows: providers.map { "\($0.displayName) · \($0.providerID)" },
        selectedProviderIndex: providerIndex,
        installationRows: installations.map {
          "\($0.displayName) · \(ProjectAgentPresentation.availabilityLabel($0.availability))"
        },
        selectedInstallationIndex: installationIndex,
        installationDetailText: detail,
        modelRows: models.map { "\($0.displayName) · \($0.modelID)" },
        modelIDs: models.map(\.modelID),
        selectedModelIndex: modelIndex,
        effortValues: effortValues,
        selectedEffortIndex: effortIndex,
        permissionValues: permissionValues,
        selectedPermissionIndex: permissionIndex,
        refreshModelsEnabled: connectionState == .connected && !busy && installation != nil,
        saveEnabled: connectionState == .connected && !busy && installation != nil
          && selectedModelID != nil,
        statusText: statusText
      )
      displayBox.store(value)
    }

    private func availableEffortValues() -> [String] {
      DirectWorkspacePresentation.effortValues(
        catalog: models.flatMap(\.supportedReasoningEfforts),
        selected: [selectedEffort],
        includesProviderDefault: true
      )
    }
  }
#endif
