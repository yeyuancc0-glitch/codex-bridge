import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceConnectionsView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var tunnelID = ""
  @State private var runtimeKey = ""
  @State private var showClearConfirmation = false
  @State private var showSaveSuccess = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "连接与集成",
          subtitle: "统一管理远程 AI 客户端、本地 MCP 客户端通道与本机已连接 Agent 引擎实例。",
          icon: "point.3.connected.trianglepath.dotted"
        )

        connectionSummaryStrip

        VStack(alignment: .leading, spacing: 12) {
          Text("远程 AI 客户端 (OpenAI Secure Tunnel)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          tunnelSection
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("本地 MCP 客户端通道")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          MCPClientConnectionsView(model: model)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("本机 Agent 引擎连接")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          BridgeServiceAgentSettingsSection(model: model)
        }
      }
      .padding(28)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("连接")
    .alert("清除 Secure Tunnel 配置？", isPresented: $showClearConfirmation) {
      Button("清除配置", role: .destructive) {
        model.clearTunnel()
        tunnelID = ""
        runtimeKey = ""
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这将从 Keychain 中移除已保存的 Runtime Key 并重置 Tunnel 绑定。")
    }
  }

  private var connectionSummaryStrip: some View {
    HStack(spacing: 12) {
      summaryItem(
        title: "XPC 本机通信",
        value: model.connectionState.label,
        symbol: model.connectionState.symbol,
        tone: serviceTone
      )

      Divider()
        .frame(height: 24)

      summaryItem(
        title: "本地 MCP 端点",
        value: model.serviceStatus?.status.mcpState == "ready" ? "已就绪" : "待检查",
        symbol: model.serviceStatus?.status.mcpState == "ready"
          ? "checkmark.circle.fill"
          : "circle.dashed",
        tone: model.serviceStatus?.status.mcpState == "ready" ? .success : .neutral
      )

      Divider()
        .frame(height: 24)

      summaryItem(
        title: "远程 Secure Tunnel",
        value: tunnelStatus.lifecycle,
        symbol: tunnelStatus.lifecycle == "ready" ? "checkmark.circle.fill" : "link",
        tone: tunnelTone
      )

      Divider()
        .frame(height: 24)

      summaryItem(
        title: "本机 Agent 引擎",
        value: "\(enabledAgentCount) 个可用",
        symbol: "cpu.fill",
        tone: enabledAgentCount > 0 ? .success : .neutral
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.8)
    )
  }

  private func summaryItem(
    title: String,
    value: String,
    symbol: String,
    tone: StatusTone
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tone.foregroundColor)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.primary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var tunnelSection: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Secure MCP 隧道", systemImage: "link.icloud.fill")
            .font(.headline)

          Spacer()

          StatusBadge(tunnelStatus.lifecycle, tone: tunnelTone)
        }

        HStack(spacing: 16) {
          HStack(spacing: 4) {
            Text("Helper 辅助工具：")
              .font(.caption)
              .foregroundStyle(.secondary)
            StatusBadge(
              tunnelStatus.helperAvailable ? "就绪" : "未打包",
              tone: tunnelStatus.helperAvailable ? .success : .warning)
          }

          HStack(spacing: 4) {
            Text("远程任务接收：")
              .font(.caption)
              .foregroundStyle(.secondary)
            StatusBadge(
              tunnelStatus.acceptsRemoteSubmissions ? "允许" : "关闭",
              tone: tunnelStatus.acceptsRemoteSubmissions ? .success : .neutral)
          }
        }

        if let configuredID = tunnelStatus.tunnelID, !configuredID.isEmpty {
          CodeSnippetBlock(text: configuredID, label: "已绑定的 Tunnel ID") {
            model.postToast("已复制 Tunnel ID")
          }
        }

        if !tunnelStatus.helperAvailable {
          CalloutBanner(
            title: "Helper 辅助工具缺失",
            message: "App 构建中未发现已签名的 tunnel-client 辅助二进制，本机 MCP 可用但无法进行远程隧道连接。",
            symbol: "exclamationmark.triangle.fill",
            tone: .warning
          )
        }

        if tunnelStatus.actionRequired {
          CalloutBanner(
            title: "需要检查 Tunnel 凭据",
            message: "Tunnel 报告需要本机处理，请核对 Tunnel ID、Runtime Key 以及当前工作区权限。",
            symbol: "exclamationmark.shield.fill",
            tone: .warning
          )
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("配置或更新凭据")
            .font(.subheadline.weight(.medium))

          TextField("OpenAI Tunnel ID (例如: tunnel_...)", text: $tunnelID)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 540)

          SecureField("Runtime API Key", text: $runtimeKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 540)
        }

        HStack(spacing: 12) {
          Button {
            let key = runtimeKey
            runtimeKey = ""
            model.configureTunnel(tunnelID: tunnelID, runtimeKey: key)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showSaveSuccess = true
            }
            Task {
              try? await Task.sleep(for: .seconds(2.5))
              withAnimation(.easeInOut(duration: 0.3)) {
                showSaveSuccess = false
              }
            }
          } label: {
            HStack(spacing: 6) {
              if showSaveSuccess {
                Image(systemName: "checkmark")
              }
              Text("保存并启动连接")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(tunnelID.isEmpty || runtimeKey.isEmpty || !tunnelStatus.helperAvailable)

          if tunnelStatus.configured {
            Button(tunnelStatus.enabled ? "断开隧道" : "重新连接") {
              if tunnelStatus.enabled {
                model.disconnectTunnel()
              } else {
                model.connectTunnel()
              }
            }
            .buttonStyle(.bordered)

            Button("清除配置", role: .destructive) {
              showClearConfirmation = true
            }
            .buttonStyle(.bordered)
          }

          if showSaveSuccess {
            HStack(spacing: 4) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("凭据已提交")
                .font(.caption)
                .foregroundStyle(.green)
            }
            .transition(.opacity)
          }
        }

        Text("安全保障：Runtime Key 只通过本机内存 XPC 发送一次并存入 macOS Keychain，绝不写入 SQLite、日志或导出文件。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear {
      if tunnelID.isEmpty {
        tunnelID = tunnelStatus.tunnelID ?? ""
      }
    }
    .onChange(of: tunnelStatus.tunnelID) { _, value in
      if runtimeKey.isEmpty {
        tunnelID = value ?? tunnelID
      }
    }
  }

  private var tunnelStatus: IPCTunnelStatus {
    model.serviceStatus?.tunnel ?? .unconfigured
  }

  private var serviceTone: StatusTone {
    switch model.connectionState {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle, .unavailable: .error
    }
  }

  private var tunnelTone: StatusTone {
    if tunnelStatus.lifecycle == "ready" { return .success }
    if tunnelStatus.actionRequired { return .warning }
    if tunnelStatus.enabled { return .running }
    return .neutral
  }

  private var enabledAgentCount: Int {
    model.agentInstallations.filter { $0.isEnabled && $0.availability == "available" }.count
  }
}
