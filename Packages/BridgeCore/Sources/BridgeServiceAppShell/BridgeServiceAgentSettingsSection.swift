import AppKit
import BridgeIPC
import SwiftUI

struct BridgeServiceAgentSettingsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var installationPendingRemoval: IPCAgentInstallationSummary?
  @State private var installationPendingReplacement: IPCAgentInstallationSummary?

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("只有在这里明确登记并通过 Probe 的本机安装才会出现在 list_agents。")
            .font(.caption)
          Text("当前阶段仍禁止通过 submit_task 启动外部 Provider；启用仅表示安装已获本机用户认可。")
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
