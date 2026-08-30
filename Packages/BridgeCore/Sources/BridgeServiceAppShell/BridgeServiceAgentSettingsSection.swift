import AppKit
import BridgeIPC
import BridgeServiceAppCore
import SwiftUI
import UniformTypeIdentifiers

struct BridgeServiceAgentSettingsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var installationPendingRemoval: IPCAgentInstallationSummary?
  @State private var installationPendingReplacement: IPCAgentInstallationSummary?

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 16) {
        headerRow

        if model.agentInstallations.isEmpty {
          emptyStateView
        } else {
          VStack(spacing: 12) {
            ForEach(model.agentInstallations, id: \.installationID) { installation in
              installationCard(installation)
            }
          }
        }
      }
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

  private var headerRow: some View {
    HStack(alignment: .center) {
      Label("本机 Agent 引擎连接", systemImage: "cpu.fill")
        .font(.headline)

      Spacer()

      providerRegistrationMenu
    }
  }

  private var emptyStateView: some View {
    VStack(spacing: 8) {
      Image(systemName: "externaldrive.badge.plus")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
      Text("尚未连接本机外部 Agent")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
      Text("点击右上角“登记 Agent”，可连接本机的 OpenCode、DeepSeek Harness 或 Antigravity 实例。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func installationCard(_ installation: IPCAgentInstallationSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: availabilitySymbol(installation.availability))
          .foregroundStyle(availabilityColor(installation.availability))

        VStack(alignment: .leading, spacing: 2) {
          Text(installation.displayName)
            .font(.subheadline.weight(.semibold))
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

      CodeSnippetBlock(text: installation.executablePath, label: "可执行路径")

      HStack(spacing: 16) {
        LabeledContent("版本", value: installation.version ?? "未识别")
        LabeledContent("ACP 协议", value: installation.protocolRevision ?? "未协商")
        LabeledContent("Adapter", value: "r\(installation.adapterRevision)")
        LabeledContent("有效能力", value: "\(installation.effectiveCapabilities.count) 项")
      }
      .font(.caption)

      if let error = installation.lastProbeError {
        CalloutBanner(
          title: "Probe 探测异常",
          message: error,
          symbol: "exclamationmark.triangle.fill",
          tone: .warning
        )
      }

      HStack(spacing: 10) {
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

        Button("移除登记", role: .destructive) {
          installationPendingRemoval = installation
        }
        .disabled(model.isManagingAgents)
      }
      .controlSize(.small)
    }
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.8)
    )
  }

  @ViewBuilder
  private var providerRegistrationMenu: some View {
    if model.agentProviders.isEmpty {
      Text("暂无可登记的 Provider")
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
        Label("登记 Agent", systemImage: "plus")
      }
      .disabled(model.isManagingAgents)
    }
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
