#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsSettingsModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsSettingsDisplay>

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var models: [MCPModelSummary] = []
    private(set) var preferences: IPCModelPreferences?
    private(set) var instructions = ""
    private(set) var directMode = "require"
    private(set) var taskStartMode = "require"
    private var busy = false
    private var statusText = "尚未加载设置。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      displayBox = AuxiliaryDisplayBox(
        value: WindowsSettingsDisplay(
          connectionState: .idle,
          modelRows: [],
          modelIDs: [],
          selectedExecutionModelIndex: nil,
          selectedSupervisorModelIndex: nil,
          effortValues: [],
          selectedExecutionEffortIndex: nil,
          selectedSupervisorEffortIndex: nil,
          accessValues: WindowsSettingsModel.accessValues,
          selectedAccessIndex: 0,
          supervisorEnabled: false,
          fastModeEnabled: false,
          directApprovalValues: WindowsSettingsModel.approvalValues,
          selectedDirectApprovalIndex: 0,
          taskStartApprovalValues: WindowsSettingsModel.approvalValues,
          selectedTaskStartApprovalIndex: 0,
          customInstructions: "",
          savePreferencesEnabled: false,
          saveInstructionsEnabled: false,
          saveDirectApprovalEnabled: false,
          saveTaskStartApprovalEnabled: false,
          statusText: statusText
        )
      )
    }

    static let accessValues = ["request-approval", "auto-review", "full-access"]
    static let approvalValues = ["require", "auto"]

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        _ = try await client.status()
        connectionState = .connected
      } catch {
        connectionState = .unavailable
        statusText = "设置读取失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
        return
      }
      var failures: [String] = []
      do {
        let catalog = try await client.modelCatalog()
        models = catalog.models
        preferences = catalog.preferences
      } catch {
        failures.append("模型")
      }
      do {
        instructions = try await client.customInstructions()
      } catch {
        failures.append("自定义指令")
      }
      do {
        directMode = try await client.directApprovalMode()
      } catch {
        failures.append("Direct 审批")
      }
      do {
        taskStartMode = try await client.taskStartApprovalMode()
      } catch {
        failures.append("任务启动审批")
      }
      statusText = failures.isEmpty ? "设置已加载。" : "部分设置读取失败：\(failures.joined(separator: "、"))"
      publishDisplay()
    }

    func savePreferences(_ value: IPCModelPreferences) async {
      guard connectionState == .connected, !busy else { return }
      guard !value.executionModel.isEmpty, !value.supervisorModel.isEmpty else {
        statusText = "执行模型和 Supervisor 模型不能为空。"
        publishDisplay()
        return
      }
      busy = true
      statusText = "正在保存模型设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      let normalized = IPCModelPreferences(
        executionModel: value.executionModel,
        executionEffort: value.executionEffort,
        supervisorModel: value.supervisorModel,
        supervisorEffort: value.supervisorEffort,
        supervisorEnabled: false,
        accessMode: value.accessMode,
        fastModeEnabled: value.fastModeEnabled
      )
      do {
        try await client.setModelPreferences(normalized)
        preferences = normalized
        statusText = "模型设置已保存。"
      } catch {
        statusText = "模型设置保存失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func saveInstructions(_ value: String) async {
      guard connectionState == .connected, !busy else { return }
      guard !value.utf8.contains(0), value.utf8.count <= 32 * 1_024 else {
        statusText = "自定义指令不能包含 NUL，且不能超过 32 KiB。"
        publishDisplay()
        return
      }
      busy = true
      statusText = "正在保存自定义指令…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        try await client.setCustomInstructions(value)
        instructions = value
        statusText = "自定义指令已保存。"
      } catch {
        statusText = "自定义指令保存失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func setDirectApprovalMode(_ mode: String) async {
      await setApprovalMode(mode, direct: true)
    }

    func setTaskStartApprovalMode(_ mode: String) async {
      await setApprovalMode(mode, direct: false)
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func setApprovalMode(_ mode: String, direct: Bool) async {
      guard Self.approvalValues.contains(mode), connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存审批设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        if direct {
          try await client.setDirectApprovalMode(mode)
          directMode = mode
        } else {
          try await client.setTaskStartApprovalMode(mode)
          taskStartMode = mode
        }
        statusText = "审批设置已保存。"
      } catch {
        statusText = "审批设置保存失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    private func publishDisplay() {
      let current = preferences
      let modelIDs = models.map(\.modelID)
      let effortValues = availableEffortValues()
      let executionIndex = current.flatMap { modelIDs.firstIndex(of: $0.executionModel) }
      let supervisorIndex = current.flatMap { modelIDs.firstIndex(of: $0.supervisorModel) }
      let executionEffortIndex = current.flatMap {
        effortValues.firstIndex(of: $0.executionEffort)
      }
      let supervisorEffortIndex = current.flatMap {
        effortValues.firstIndex(of: $0.supervisorEffort)
      }
      let accessIndex = current.flatMap { Self.accessValues.firstIndex(of: $0.accessMode) }
      let directIndex = Self.approvalValues.firstIndex(of: directMode)
      let taskIndex = Self.approvalValues.firstIndex(of: taskStartMode)
      let value = WindowsSettingsDisplay(
        connectionState: connectionState,
        modelRows: models.map { "\($0.displayName) · \($0.modelID)" },
        modelIDs: modelIDs,
        selectedExecutionModelIndex: executionIndex,
        selectedSupervisorModelIndex: supervisorIndex,
        effortValues: effortValues,
        selectedExecutionEffortIndex: executionEffortIndex,
        selectedSupervisorEffortIndex: supervisorEffortIndex,
        accessValues: Self.accessValues,
        selectedAccessIndex: accessIndex,
        supervisorEnabled: false,
        fastModeEnabled: current?.fastModeEnabled ?? false,
        directApprovalValues: Self.approvalValues,
        selectedDirectApprovalIndex: directIndex,
        taskStartApprovalValues: Self.approvalValues,
        selectedTaskStartApprovalIndex: taskIndex,
        customInstructions: instructions,
        savePreferencesEnabled: connectionState == .connected && !busy && current != nil,
        saveInstructionsEnabled: connectionState == .connected && !busy,
        saveDirectApprovalEnabled: connectionState == .connected && !busy,
        saveTaskStartApprovalEnabled: connectionState == .connected && !busy,
        statusText: statusText
      )
      displayBox.store(value)
    }

    private func availableEffortValues() -> [String] {
      DirectWorkspacePresentation.effortValues(
        catalog: models.flatMap(\.reasoningEfforts),
        selected: [preferences?.executionEffort, preferences?.supervisorEffort].compactMap { $0 }
      )
    }
  }
#endif
