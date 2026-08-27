import AppKit
import BridgeIPC
import SwiftUI

struct BridgeServiceAgentSettingsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var installationPendingRemoval: IPCAgentInstallationSummary?
  @State private var installationPendingReplacement: IPCAgentInstallationSummary?
  @State private var submitProviderID = "opencode"
  @State private var submitPrompt = ""
  @State private var antigravityModel = ""
  @State private var antigravityEffort = ""

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("只有在这里明确登记并通过 Probe 的本机安装才会出现在 list_agents。")
            .font(.caption)
          Text("已启用且 Probe 通过的 Provider 安装可以通过 submit_task 提交任务；每个任务仍需本机批准。")
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
        LabeledContent("协议", value: installation.protocolRevision ?? "未协商")
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
    if provider.providerID == "antigravity" {
      panel.message = "请选择官方 agy 可执行文件；macOS 默认安装位置为 ~/.local/bin/agy。"
    }
    panel.prompt = "登记并 Probe"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.registerAgentInstallation(
      providerID: provider.providerID,
      displayName: provider.displayName,
      executableURL: url
    )
  }

  @ViewBuilder
  private var agentSubmitCard: some View {
    let selectable = model.agentInstallations.filter {
      $0.providerID == submitProviderID && $0.isEnabled && $0.availability == "available"
    }
    let selectedInstallation = selectable.first
    let canSelectModel = model.supportsAgentModelSelection(
      providerID: submitProviderID,
      installationID: selectedInstallation?.installationID
    )
    let canSelectEffort = model.supportsAgentEffortSelection(
      providerID: submitProviderID,
      installationID: selectedInstallation?.installationID
    )
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Text("本机 Agent 任务")
        .font(.body.weight(.semibold))
      Text(submitProviderDescription)
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Provider", selection: $submitProviderID) {
        ForEach(
          Array(Set(model.agentInstallations.map(\.providerID))).sorted(), id: \.self
        ) { id in
          Text(AgentProviderPresentation.displayName(id)).tag(id)
        }
      }
      .pickerStyle(.menu)

      if submitProviderID == "opencode" {
        Picker("默认执行模式", selection: openCodeDefaultPermissionModeBinding) {
          Text("OpenCode 原生 Build（工作区可写）").tag("build")
          Text("OpenCode 原生 Plan（只读）").tag("plan")
        }
        .pickerStyle(.menu)
        .disabled(model.isRefreshingAgentModels)
        .help("仅当任务没有显式 permission_mode 时使用；项目权限仍会限制写入")
      } else if submitProviderID == "antigravity" {
        LabeledContent("执行模式", value: "只读（macOS 项目写入边界）")
          .font(.caption)
      }

      if selectable.isEmpty {
        Text("该 Provider 暂无已启用的可用安装")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if canSelectModel {
        Picker(
          submitProviderID == "opencode" ? "默认模型" : "任务模型",
          selection: agentModelSelectionBinding
        ) {
          Text("Provider 默认").tag("")
          if let current = selectedSubmitModel,
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
            modelID: selectedSubmitModel
          )
        ) {
          if submitProviderID == "opencode" {
            guard
              !model.consumeAgentModelHydrationSuppression(
                installationID: selectedInstallation?.installationID,
                projectID: model.selectedProjectID,
                modelID: selectedSubmitModel
              )
            else { return }
          }
          await model.hydrateAgentModelState(
            installationID: selectedInstallation?.installationID,
            providerID: submitProviderID,
            modelID: selectedSubmitModel
          )
        }

        HStack(spacing: 10) {
          Button {
            model.refreshAgentModelCatalog(
              installationID: selectedInstallation?.installationID,
              providerID: submitProviderID,
              selectedModelID: selectedSubmitModel
            )
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
          .accessibilityLabel("刷新 Agent 模型列表")
          .accessibilityHint("从当前 Provider 安装重新读取模型目录")

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

      if canSelectEffort {
        Picker(
          submitProviderID == "opencode" ? "默认推理强度" : "任务推理强度",
          selection: agentEffortSelectionBinding
        ) {
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
        .help("仅展示当前 Provider 对所选模型实际声明的推理强度")
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
            installationID: selectable.first?.installationID,
            model: selectedSubmitModel,
            effort: selectedSubmitEffort,
            permissionMode: submitProviderID == "antigravity" ? "read-only" : nil,
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

  private var agentModelSelectionBinding: Binding<String> {
    Binding(
      get: {
        selectedSubmitModel ?? ""
      },
      set: { value in
        if submitProviderID != "opencode" {
          guard
            model.supportsAgentModelSelection(
              providerID: submitProviderID,
              installationID: selectedSubmitInstallation?.installationID
            )
          else {
            antigravityModel = ""
            antigravityEffort = ""
            return
          }
          antigravityModel = value
          antigravityEffort = ""
          return
        }
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

  private var agentEffortSelectionBinding: Binding<String> {
    Binding(
      get: {
        selectedSubmitEffort ?? ""
      },
      set: { value in
        if submitProviderID != "opencode" {
          guard
            model.supportsAgentEffortSelection(
              providerID: submitProviderID,
              installationID: selectedSubmitInstallation?.installationID
            )
          else {
            antigravityEffort = ""
            return
          }
          antigravityEffort = value
          return
        }
        let selected = value.isEmpty ? nil : value
        guard selected != model.openCodeDefaultEffort else { return }
        model.saveOpenCodeEffort(selected)
      }
    )
  }

  private var selectedSubmitInstallation: IPCAgentInstallationSummary? {
    model.agentInstallations.first {
      $0.providerID == submitProviderID
        && $0.isEnabled
        && $0.availability == "available"
    }
  }

  private var selectedSubmitModel: String? {
    guard
      model.supportsAgentModelSelection(
        providerID: submitProviderID,
        installationID: selectedSubmitInstallation?.installationID
      )
    else {
      return nil
    }
    let value =
      submitProviderID == "opencode"
      ? model.openCodeDefaultModel ?? ""
      : antigravityModel
    return value.isEmpty ? nil : value
  }

  private var selectedSubmitEffort: String? {
    guard
      model.supportsAgentEffortSelection(
        providerID: submitProviderID,
        installationID: selectedSubmitInstallation?.installationID
      )
    else {
      return nil
    }
    let value =
      submitProviderID == "opencode"
      ? model.openCodeDefaultEffort ?? ""
      : antigravityEffort
    return value.isEmpty ? nil : value
  }

  private var selectedAgentModel: IPCAgentModelSummary? {
    if let modelID = selectedSubmitModel {
      return model.agentModelOptions.first(where: { $0.modelID == modelID })
    }
    return model.agentModelOptions.first(where: { !$0.supportedReasoningEfforts.isEmpty })
  }

  private var submitProviderDescription: String {
    switch submitProviderID {
    case "opencode":
      "提交后进入工作台等待本机批准；OpenCode 使用原生 Build/Plan，网络访问由原生 permissions 控制。"
    case "antigravity":
      "通过官方 agy stream-json 和 CLI 缓存认证执行；可能需要与桌面版分开登录。V1 仅开放项目只读任务，无法交互批准的工具会被拒绝。"
    default:
      "提交后进入工作台等待本机批准；实际能力与安全保证以当前 Provider Probe 为准。"
    }
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
