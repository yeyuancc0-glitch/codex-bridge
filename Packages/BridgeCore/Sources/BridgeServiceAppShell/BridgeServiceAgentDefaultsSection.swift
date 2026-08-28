import BridgeIPC
import SwiftUI

struct BridgeServiceAgentDefaultsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  let providerID: String

  @State private var selectedInstallationID = ""

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        installationSelection

        if selectableInstallations.isEmpty {
          Label(
            "尚未登记可用安装，请在“本机 Agent Provider”区域登记并 Probe。",
            systemImage: "externaldrive.badge.questionmark"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }

        if provider?.supportsModelSelection == true {
          modelSelection
          modelCatalogActions
        } else {
          Text("该 Provider 不提供模型选择。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if provider?.supportsEffortSelection == true {
          effortSelection
        } else {
          Text("该 Provider 不提供推理强度选择。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        permissionSelection

        Text("MCP 客户端未显式指定配置时，任务将使用此 Provider 的默认设置。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    } header: {
      Label(
        "\(providerDisplayName) 执行任务默认偏好",
        systemImage: AgentProviderPresentation.systemImage(providerID)
      )
    }
    .task(id: hydrationID) {
      guard
        !model.consumeAgentModelHydrationSuppression(
          providerID: providerID,
          installationID: selectedInstallation?.installationID,
          projectID: model.selectedProjectID,
          modelID: providerDefault.model
        )
      else { return }
      await model.hydrateAgentModelState(
        installationID: selectedInstallation?.installationID,
        providerID: providerID
      )
    }
  }

  @ViewBuilder
  private var installationSelection: some View {
    if selectableInstallations.count > 1 {
      Picker("安装", selection: installationBinding) {
        ForEach(selectableInstallations, id: \.installationID) { installation in
          Text(installation.displayName + " · " + installation.installationID)
            .tag(installation.installationID)
        }
      }
      .pickerStyle(.menu)
    } else if let installation = selectedInstallation {
      LabeledContent("安装", value: installation.displayName)
        .font(.caption)
    }
  }

  private var modelSelection: some View {
    Picker("默认模型", selection: modelBinding) {
      Text("Provider 默认").tag("")
      if let current = providerDefault.model,
        !model.agentModelOptions(for: providerID).contains(where: { $0.modelID == current })
      {
        Text("当前设置 · \(current)").tag(current)
      }
      ForEach(model.agentModelOptions(for: providerID), id: \.modelID) { item in
        Text("\(item.displayName) · \(item.modelID)")
          .tag(item.modelID)
      }
    }
    .pickerStyle(.menu)
    .disabled(!canSelectModels || model.isRefreshingAgentModels(for: providerID))
    .overlay(alignment: .trailing) {
      if model.isRefreshingAgentModels(for: providerID) {
        ProgressView()
          .controlSize(.small)
          .padding(.trailing, 8)
      }
    }
  }

  private var modelCatalogActions: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button {
          model.refreshAgentModelCatalog(
            installationID: selectedInstallation?.installationID,
            providerID: providerID
          )
        } label: {
          if model.isRefreshingAgentModels(for: providerID) {
            ProgressView()
              .controlSize(.small)
            Text("正在刷新模型列表…")
          } else {
            Label("刷新模型列表", systemImage: "arrow.clockwise")
          }
        }
        .controlSize(.small)
        .disabled(
          !canSelectModels
            || model.isRefreshingAgentModels(for: providerID)
            || model.isManagingAgents
        )
        .accessibilityLabel("刷新 \(providerDisplayName) 模型列表")
        .accessibilityHint("从当前 Provider 安装重新读取模型目录")

        if !model.agentModelOptions(for: providerID).isEmpty {
          Text("\(model.agentModelOptions(for: providerID).count) 个模型")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let error = model.agentModelRefreshError(for: providerID) {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
  }

  private var effortSelection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("推理强度", selection: effortBinding) {
        Text("Provider 默认").tag("")
        if let current = providerDefault.effort,
          !supportedEfforts.contains(current)
        {
          Text("当前设置 · \(current)").tag(current)
        }
        ForEach(supportedEfforts, id: \.self) { effort in
          Text("\(reasoningTitle(effort)) · \(effort)").tag(effort)
        }
      }
      .pickerStyle(.menu)
      .disabled(!canSelectEffort || model.isRefreshingAgentModels(for: providerID))

      if supportedEfforts.isEmpty {
        Text("当前模型不提供可选推理强度，使用 Provider 默认。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var permissionSelection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if provider?.supportsWorkspaceWrite == true {
        Picker("访问权限", selection: permissionBinding) {
          Text(writeModeTitle).tag(writeModeValue)
          Text(readModeTitle).tag(readModeValue)
        }
        .pickerStyle(.menu)
        .disabled(!canSelectWorkspaceWrite && selectedInstallation != nil)
      } else {
        Text("访问权限：只读（Provider 能力限制）")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let installation = selectedInstallation,
        provider?.supportsWorkspaceWrite == true,
        !installationSupportsWorkspaceWrite(installation)
      {
        Text("当前安装的有效能力不包含工作区写入，将按只读执行。")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private var provider: IPCAgentProviderSummary? {
    model.agentProviders.first(where: { $0.providerID == providerID })
  }

  private var providerDisplayName: String {
    provider?.displayName ?? fallbackDisplayName
  }

  private var fallbackDisplayName: String {
    switch providerID {
    case "opencode": "OpenCode"
    case "deepseek-harness": "DeepSeek Harness"
    case "antigravity": "Antigravity"
    default: providerID
    }
  }

  private var selectableInstallations: [IPCAgentInstallationSummary] {
    model.agentInstallations.filter {
      $0.providerID == providerID && $0.isEnabled && $0.availability == "available"
    }
  }

  private var selectedInstallation: IPCAgentInstallationSummary? {
    if let selected = selectableInstallations.first(where: {
      $0.installationID == selectedInstallationID
    }) {
      return selected
    }
    return selectableInstallations.first
  }

  private var installationBinding: Binding<String> {
    Binding(
      get: { selectedInstallation?.installationID ?? "" },
      set: { selectedInstallationID = $0 }
    )
  }

  private var providerDefault: IPCAgentModelDefaultResponse {
    model.agentModelDefault(for: providerID)
  }

  private var hydrationID: AgentModelHydrationID {
    AgentModelHydrationID(
      providerID: providerID,
      installationID: selectedInstallation?.installationID,
      projectID: model.selectedProjectID,
      modelID: providerDefault.model
    )
  }

  private var canSelectModels: Bool {
    guard provider?.supportsModelSelection == true else { return false }
    guard let installation = selectedInstallation else { return false }
    return installation.effectiveCapabilities.contains("selection.model")
  }

  private var selectedModel: IPCAgentModelSummary? {
    model.agentSelectedModel(for: providerID)
  }

  private var supportedEfforts: [String] {
    selectedModel?.supportedReasoningEfforts ?? []
  }

  private var canSelectEffort: Bool {
    guard provider?.supportsEffortSelection == true else { return false }
    return model.supportsAgentEffortSelection(
      providerID: providerID,
      installationID: selectedInstallation?.installationID
    )
  }

  private var canSelectWorkspaceWrite: Bool {
    guard let installation = selectedInstallation else { return true }
    return installationSupportsWorkspaceWrite(installation)
  }

  private func installationSupportsWorkspaceWrite(
    _ installation: IPCAgentInstallationSummary
  ) -> Bool {
    installation.effectiveCapabilities.contains("workspace.write_in_place")
      || installation.effectiveCapabilities.contains("workspace.write_isolated")
  }

  private var writeModeValue: String {
    providerID == "opencode" ? "build" : "workspace-write"
  }

  private var readModeValue: String {
    providerID == "opencode" ? "plan" : "read-only"
  }

  private var writeModeTitle: String {
    switch providerID {
    case "opencode": "工作区可写（Build）"
    case "antigravity": "工作区可写（Accept Edits）"
    default: "工作区可写"
    }
  }

  private var readModeTitle: String {
    switch providerID {
    case "opencode", "antigravity": "只读（Plan）"
    default: "只读"
    }
  }

  private var modelBinding: Binding<String> {
    Binding(
      get: { providerDefault.model ?? "" },
      set: { value in
        let selected = value.isEmpty ? nil : value
        guard selected != providerDefault.model else { return }
        model.saveAgentModelDefault(selected, providerID: providerID)
      }
    )
  }

  private var effortBinding: Binding<String> {
    Binding(
      get: { providerDefault.effort ?? "" },
      set: { value in
        let selected = value.isEmpty ? nil : value
        guard selected != providerDefault.effort else { return }
        model.saveAgentEffort(selected, providerID: providerID)
      }
    )
  }

  private var permissionBinding: Binding<String> {
    Binding(
      get: {
        let current = providerDefault.permissionMode
        return current == readModeValue ? readModeValue : writeModeValue
      },
      set: { value in
        guard value == writeModeValue || value == readModeValue else { return }
        guard value != permissionBindingValue else { return }
        model.saveAgentPermissionMode(value, providerID: providerID)
      }
    )
  }

  private var permissionBindingValue: String {
    let current = providerDefault.permissionMode
    return current == readModeValue ? readModeValue : writeModeValue
  }

  private func reasoningTitle(_ effort: String) -> String {
    switch effort.lowercased() {
    case "minimal": "最低"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh", "extra_high": "极高"
    default: effort
    }
  }
}
