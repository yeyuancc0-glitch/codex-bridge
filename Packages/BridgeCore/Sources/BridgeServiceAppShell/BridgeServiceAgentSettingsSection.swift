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
  @State private var submitSkillName = ""
  @State private var submitPrompt = ""

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("只有在这里明确登记并通过 Probe 的本机安装才会出现在 list_agents。")
            .font(.caption)
          Text("已启用且 Probe 通过的安装可以通过 submit_task 提交任务；每个任务仍需本机批准，具体能力以 Provider 有效能力为准。")
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
    let chosenInstallation = selectedInstallation(in: selectable)
    let provider = selectedProvider
    let providerDefault = model.agentModelDefault(for: submitProviderID)
    let supportsWorkspaceWrite = supportsWorkspaceWrite(
      provider: provider,
      installation: chosenInstallation
    )
    let supportsModelSelection = supports(
      provider?.supportsModelSelection,
      installation: chosenInstallation,
      capability: "selection.model"
    )
    let supportsEffortSelection =
      provider?.supportsEffortSelection == true
      && model.supportsAgentEffortSelection(
        providerID: submitProviderID,
        installationID: chosenInstallation?.installationID
      )
    let supportsSkillSelection = supports(
      provider?.supportsSkillSelection,
      installation: chosenInstallation
    )
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Text("本机 Agent 任务")
        .font(.body.weight(.semibold))
      if supportsWorkspaceWrite {
        Text("提交后进入工作台等待本机批准；当前 Provider 支持只读和工作区写入模式。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label("只读 · Provider 能力限制", systemImage: "lock.shield.fill")
          .font(.caption)
          .foregroundStyle(.orange)
        Text("Bridge 会按 Provider 有效能力限制工作区写入和执行期权限。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Provider", selection: providerSelection) {
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

      if selectable.isEmpty {
        Text("该 Provider 暂无已启用的可用安装")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if selectable.count > 1 {
        Picker("安装", selection: installationSelection(selectable)) {
          Text("请选择安装").tag("")
          ForEach(selectable, id: \.installationID) { installation in
            Text(installation.displayName + " · " + installation.installationID)
              .tag(installation.installationID)
          }
        }
        .pickerStyle(.menu)
      }

      if supportsSkillSelection, !model.skills.isEmpty {
        Picker("Skill", selection: $submitSkillName) {
          Text("不指定").tag("")
          ForEach(model.skills) { skill in
            Text(skill.name).tag(skill.name)
          }
        }
        .pickerStyle(.menu)
        .help("将已加载的项目 Skill 注入本次任务")
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
            installationID: chosenInstallation?.installationID,
            model: supportsModelSelection ? providerDefault.model : nil,
            effort: supportsEffortSelection
              ? model.agentExecutionEffort(for: submitProviderID) : nil,
            permissionMode: supportsWorkspaceWrite ? nil : "read-only",
            prompt: submitPrompt,
            skillName: selectedSkillName
          )
          submitPrompt = ""
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(
          submitPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectable.isEmpty
            || chosenInstallation == nil
            || provider == nil
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

  private var providerSelection: Binding<String> {
    Binding(
      get: { submitProviderID },
      set: { value in
        guard value != submitProviderID else { return }
        submitProviderID = value
        submitInstallationID = ""
        submitSkillName = ""
      }
    )
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
        if selectable.contains(where: { $0.installationID == submitInstallationID }) {
          return submitInstallationID
        }
        return selectable.count == 1 ? selectable[0].installationID : ""
      },
      set: { submitInstallationID = $0 }
    )
  }

  private func selectedInstallation(
    in selectable: [IPCAgentInstallationSummary]
  ) -> IPCAgentInstallationSummary? {
    if let selected = selectable.first(where: { $0.installationID == submitInstallationID }) {
      return selected
    }
    return selectable.count == 1 ? selectable[0] : nil
  }

  private func supports(
    _ providerCapability: Bool?,
    installation: IPCAgentInstallationSummary?,
    capability: String? = nil
  ) -> Bool {
    guard providerCapability == true, let installation else { return false }
    guard let capability else { return true }
    return installation.effectiveCapabilities.contains(capability)
  }

  private func supportsWorkspaceWrite(
    provider: IPCAgentProviderSummary?,
    installation: IPCAgentInstallationSummary?
  ) -> Bool {
    guard provider?.supportsWorkspaceWrite == true, let installation else { return false }
    return installation.effectiveCapabilities.contains("workspace.write_in_place")
      || installation.effectiveCapabilities.contains("workspace.write_isolated")
  }

  private var selectedSkillName: String? {
    guard selectedProvider?.supportsSkillSelection == true,
      !submitSkillName.isEmpty,
      model.skills.contains(where: { $0.name == submitSkillName })
    else { return nil }
    return submitSkillName
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
