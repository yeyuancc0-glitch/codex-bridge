import AppKit
import BridgeIPC
import SwiftUI
import UniformTypeIdentifiers

struct BridgeServiceAgentSettingsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var installationPendingRemoval: IPCAgentInstallationSummary?
  @State private var installationPendingReplacement: IPCAgentInstallationSummary?
  @State private var submitProviderID = "opencode"
  @State private var submitInstallationID = ""
  @State private var submitPrompt = ""

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("只有在这里明确登记并通过 Probe 的本机安装才会出现在 list_agents。")
            .font(.caption)
          Text("已启用且 Probe 通过的安装可以通过 submit_task 提交任务；每个任务仍需本机批准。DeepSeek Harness 为实验性只读。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        providerRegistrationMenu
      }

      if model.agentInstallations.isEmpty {
        Label("尚未登记外部 Agent 安装", systemImage: "externaldrive.badge.questionmark")
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ForEach(model.agentInstallations, id: \.installationID) { installation in
          installationRow(installation)
        }
      }

      agentSubmitCard
    } header: {
      Label("本机 Agent Provider", systemImage: "point.3.connected.trianglepath.dotted")
    }
    .alert(
      "接受二进制替换并重新验证？",
      isPresented: Binding(
        get: { installationPendingReplacement != nil },
        set: { visible in
          if !visible { installationPendingReplacement = nil }
        }
      ),
      presenting: installationPendingReplacement
    ) { installation in
      Button("接受替换并 Probe") {
        installationPendingReplacement = nil
        model.reprobeAgentInstallation(
          installation.installationID,
          acceptReplacement: true
        )
      }
      Button("取消", role: .cancel) {
        installationPendingReplacement = nil
      }
    } message: { installation in
      Text(
        "仅当你确认“\(installation.displayName)”的可执行文件确实由你更新后才能继续。Bridge 会重新冻结文件身份并执行版本 Probe。"
      )
    }
    .alert(
      "移除 Agent 安装？",
      isPresented: Binding(
        get: { installationPendingRemoval != nil },
        set: { visible in
          if !visible { installationPendingRemoval = nil }
        }
      ),
      presenting: installationPendingRemoval
    ) { installation in
      Button("移除", role: .destructive) {
        installationPendingRemoval = nil
        model.removeAgentInstallation(installation.installationID)
      }
      Button("取消", role: .cancel) {
        installationPendingRemoval = nil
      }
    } message: { installation in
      Text("只删除“\(installation.displayName)”的 Bridge 登记记录，不会删除本机可执行文件或 Provider 登录数据。")
    }
  }

  @ViewBuilder
  private var providerRegistrationMenu: some View {
    if model.agentProviders.isEmpty {
      Text("没有可登记的 Provider Adapter")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Menu {
        ForEach(model.agentProviders, id: \.providerID) { provider in
          Button(provider.displayName) {
            chooseExecutable(for: provider)
          }
        }
      } label: {
        Label("登记安装", systemImage: "plus")
      }
      .disabled(model.isManagingAgents)
    }
  }

  private func installationRow(_ installation: IPCAgentInstallationSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: availabilitySymbol(installation.availability))
          .foregroundStyle(availabilityColor(installation.availability))

        VStack(alignment: .leading, spacing: 2) {
          Text(installation.displayName)
            .font(.body.weight(.semibold))
          Text(installation.providerID + " · " + installation.installationID)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }

        Spacer()

        StatusBadge(
          availabilityTitle(installation.availability),
          tone: availabilityTone(installation.availability)
        )

        Toggle(
          "启用",
          isOn: Binding(
            get: { installation.isEnabled },
            set: {
              model.setAgentInstallationEnabled(
                installation.installationID,
                enabled: $0
              )
            }
          )
        )
        .toggleStyle(.switch)
        .disabled(
          model.isManagingAgents
            || (!installation.isEnabled && installation.availability != "available")
        )
      }

      Text(installation.executablePath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)

      HStack(spacing: 16) {
        LabeledContent("版本", value: installation.version ?? "未识别")
        LabeledContent("ACP", value: installation.protocolRevision ?? "未协商")
        LabeledContent("Adapter", value: "r\(installation.adapterRevision)")
        LabeledContent("能力", value: "\(installation.effectiveCapabilities.count) 项")
      }
      .font(.caption)

      if let error = installation.lastProbeError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }

      HStack {
        Button("重新 Probe") {
          model.reprobeAgentInstallation(
            installation.installationID,
            acceptReplacement: false
          )
        }
        .disabled(model.isManagingAgents)

        if installation.availability == "needs_review" {
          Button("接受替换并 Probe") {
            installationPendingReplacement = installation
          }
          .disabled(model.isManagingAgents)
        }

        Spacer()

        Button("移除", role: .destructive) {
          installationPendingRemoval = installation
        }
        .disabled(model.isManagingAgents)
      }
      .controlSize(.small)
    }
    .padding(.vertical, 8)
  }

  private func chooseExecutable(for provider: IPCAgentProviderSummary) {
    let panel = NSOpenPanel()
    panel.title = "选择 \(provider.displayName) 可执行文件"
    panel.prompt = provider.requiresConfiguration ? "下一步" : "登记并 Probe"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let configurationURL: URL?
    if provider.requiresConfiguration {
      let configurationPanel = NSOpenPanel()
      configurationPanel.title = "选择 \(provider.displayName) cordis.yml"
      configurationPanel.message =
        "请选择项目外的只读 cordis.yml。Bridge 不读取或保存 .env 和 API Key。"
      configurationPanel.prompt = "登记并 Probe"
      configurationPanel.canChooseFiles = true
      configurationPanel.canChooseDirectories = false
      configurationPanel.allowsMultipleSelection = false
      configurationPanel.resolvesAliases = true
      configurationPanel.allowedContentTypes = ["yml", "yaml"].compactMap {
        UTType(filenameExtension: $0)
      }
      guard configurationPanel.runModal() == .OK, let selected = configurationPanel.url else {
        return
      }
      configurationURL = selected
    } else {
      configurationURL = nil
    }
    model.registerAgentInstallation(
      providerID: provider.providerID,
      displayName: provider.displayName,
      executableURL: url,
      configurationURL: configurationURL
    )
  }

  @ViewBuilder
  private var agentSubmitCard: some View {
    let selectable = model.agentInstallations.filter {
      $0.providerID == submitProviderID && $0.isEnabled && $0.availability == "available"
    }
    let selectedInstallation =
      selectable.first(where: { $0.installationID == submitInstallationID })
      ?? selectable.first
    let provider = selectedProvider
    let supportsWorkspaceWrite = provider?.supportsWorkspaceWrite ?? true
    let supportsModelSelection = provider?.supportsModelSelection ?? true
    let supportsEffortSelection = provider?.supportsEffortSelection ?? true
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Text("本机 Agent 任务")
        .font(.body.weight(.semibold))
      if supportsWorkspaceWrite {
        Text("提交后进入工作台等待本机批准；OpenCode 使用原生 Build/Plan，网络访问由原生 permissions 控制。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label("实验性只读 · 仅新会话", systemImage: "lock.shield.fill")
          .font(.caption)
          .foregroundStyle(.orange)
        Text("Bridge 会自动拒绝 Provider 的执行期权限请求；网络控制面不由 Bridge 保证阻断。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Provider", selection: $submitProviderID) {
        ForEach(providerIDs, id: \.self) { id in
          Text(providerDisplayName(id)).tag(id)
        }
      }
      .pickerStyle(.menu)

      if !supportsWorkspaceWrite {
        Text("权限模式：只读（自动拒绝执行期权限请求）")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if supportsWorkspaceWrite {
        Picker("默认执行模式", selection: openCodeDefaultPermissionModeBinding) {
          Text("OpenCode 原生 Build（工作区可写）").tag("build")
          Text("OpenCode 原生 Plan（只读）").tag("plan")
        }
        .pickerStyle(.menu)
        .disabled(model.isRefreshingAgentModels)
        .help("仅当任务没有显式 permission_mode 时使用；项目权限仍会限制写入")
      }

      if selectable.isEmpty {
        Text("该 Provider 暂无已启用的可用安装")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if selectable.count > 1 {
        Picker("安装", selection: installationSelection(selectable)) {
          ForEach(selectable, id: \.installationID) { installation in
            Text(installation.displayName + " · " + installation.installationID)
              .tag(installation.installationID)
          }
        }
        .pickerStyle(.menu)
      }

      if supportsModelSelection {
        Picker("默认模型", selection: agentModelDefaultBinding) {
          Text("Provider 默认").tag("")
          if let current = model.openCodeDefaultModel,
            !model.agentModelOptions.contains(where: { $0.modelID == current })
          {
            Text("当前设置 · \(current)").tag(current)
          }
          ForEach(model.agentModelOptions, id: \.modelID) { item in
            Text(item.displayName).tag(item.modelID)
          }
        }
        .pickerStyle(.menu)
        .disabled(model.isRefreshingAgentModels)
        .task(
          id: AgentModelHydrationID(
            installationID: selectedInstallation?.installationID,
            projectID: model.selectedProjectID,
            modelID: model.openCodeDefaultModel
          )
        ) {
          guard
            !model.consumeAgentModelHydrationSuppression(
              installationID: selectedInstallation?.installationID,
              projectID: model.selectedProjectID,
              modelID: model.openCodeDefaultModel
            )
          else { return }
          await model.hydrateAgentModelState(installationID: selectedInstallation?.installationID)
        }

        HStack(spacing: 10) {
          Button {
            model.refreshAgentModelCatalog(installationID: selectedInstallation?.installationID)
          } label: {
            if model.isRefreshingAgentModels {
              ProgressView()
                .controlSize(.small)
              Text("正在刷新模型列表…")
            } else {
              Label("刷新模型列表", systemImage: "arrow.clockwise")
            }
          }
          .controlSize(.small)
          .disabled(
            selectable.isEmpty
              || model.isRefreshingAgentModels
              || model.isManagingAgents
          )
          .accessibilityLabel("刷新 OpenCode 模型列表")
          .accessibilityHint("从当前 OpenCode ACP 安装重新读取模型目录")

          if !model.agentModelOptions.isEmpty {
            Text("\(model.agentModelOptions.count) 个模型")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let refreshError = model.agentModelRefreshError {
          Label(refreshError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
      }

      if supportsEffortSelection {
        Picker("默认推理强度", selection: openCodeDefaultEffortBinding) {
          Text("Provider 默认").tag("")
          if let current = selectedAgentModel,
            !current.supportedReasoningEfforts.isEmpty
          {
            ForEach(current.supportedReasoningEfforts, id: \.self) { effort in
              Text(effort).tag(effort)
            }
          }
        }
        .pickerStyle(.menu)
        .disabled(model.isRefreshingAgentModels)
        .help("OpenCode 通过 ACP 的 effort 选项提供模型支持的推理强度")
        if selectedAgentModel?.supportedReasoningEfforts.isEmpty != false {
          Text("当前模型不提供可选推理强度，使用 Provider 默认")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      TextField("任务描述", text: $submitPrompt, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...4)

      HStack {
        Spacer()
        Button("提交任务") {
          model.submitAgentTask(
            projectID: model.selectedProjectID ?? (model.projects.first?.projectID ?? ""),
            providerID: submitProviderID,
            installationID: selectedInstallation?.installationID,
            model: supportsModelSelection ? model.openCodeDefaultModel : nil,
            effort: supportsEffortSelection ? model.openCodeDefaultEffort : nil,
            permissionMode: supportsWorkspaceWrite ? nil : "read-only",
            prompt: submitPrompt
          )
          submitPrompt = ""
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(
          submitPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectable.isEmpty
            || model.selectedProjectID == nil && model.projects.isEmpty
        )
      }
    }
    .padding(.vertical, 6)
  }

  private var providerIDs: [String] {
    let ids = Set(model.agentProviders.map(\.providerID))
      .union(model.agentInstallations.map(\.providerID))
    return ids.sorted()
  }

  private var selectedProvider: IPCAgentProviderSummary? {
    model.agentProviders.first(where: { $0.providerID == submitProviderID })
  }

  private func providerDisplayName(_ providerID: String) -> String {
    model.agentProviders.first(where: { $0.providerID == providerID })?.displayName
      ?? providerID
  }

  private func installationSelection(
    _ selectable: [IPCAgentInstallationSummary]
  ) -> Binding<String> {
    Binding(
      get: {
        selectable.contains(where: { $0.installationID == submitInstallationID })
          ? submitInstallationID
          : selectable.first?.installationID ?? ""
      },
      set: { submitInstallationID = $0 }
    )
  }

  private var agentModelDefaultBinding: Binding<String> {
    Binding(
      get: { model.openCodeDefaultModel ?? "" },
      set: { value in
        let selected = value.isEmpty ? nil : value
        guard selected != model.openCodeDefaultModel else { return }
        model.saveAgentModelDefault(selected)
      }
    )
  }

  private var openCodeDefaultPermissionModeBinding: Binding<String> {
    Binding(
      get: { model.openCodeDefaultPermissionMode },
      set: { value in
        guard value == "build" || value == "plan",
          value != model.openCodeDefaultPermissionMode
        else { return }
        model.saveOpenCodePermissionMode(value)
      }
    )
  }

  private var openCodeDefaultEffortBinding: Binding<String> {
    Binding(
      get: { model.openCodeDefaultEffort ?? "" },
      set: { value in
        let selected = value.isEmpty ? nil : value
        guard selected != model.openCodeDefaultEffort else { return }
        model.saveOpenCodeEffort(selected)
      }
    )
  }

  private var selectedAgentModel: IPCAgentModelSummary? {
    if let modelID = model.openCodeDefaultModel {
      return model.agentModelOptions.first(where: { $0.modelID == modelID })
    }
    return model.agentModelOptions.first(where: { !$0.supportedReasoningEfforts.isEmpty })
  }

  private func availabilityTitle(_ value: String) -> String {
    switch value {
    case "available": "可用"
    case "needs_review": "需复核"
    default: "不可用"
    }
  }

  private func availabilityTone(_ value: String) -> StatusTone {
    switch value {
    case "available": .success
    case "needs_review": .warning
    default: .error
    }
  }

  private func availabilitySymbol(_ value: String) -> String {
    switch value {
    case "available": "checkmark.shield.fill"
    case "needs_review": "exclamationmark.shield.fill"
    default: "xmark.shield.fill"
    }
  }

  private func availabilityColor(_ value: String) -> Color {
    switch value {
    case "available": .green
    case "needs_review": .orange
    default: .red
    }
  }
}
