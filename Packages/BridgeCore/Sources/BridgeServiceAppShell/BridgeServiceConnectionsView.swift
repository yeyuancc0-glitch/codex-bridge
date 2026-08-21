import BridgeIPC
import BridgeMCP
import SwiftUI

struct BridgeServiceConnectionsView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var tunnelID = ""
  @State private var runtimeKey = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "连接与服务",
          subtitle: "后台 LaunchAgent Service 持有 MCP 与 Secure Tunnel，关闭可视化 App 不会停止任务。",
          icon: "point.3.connected.trianglepath.dotted"
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("后台守护服务 (Service)")
            .font(.headline)
            .foregroundStyle(.secondary)

          serviceSection
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("本地 MCP 通道")
            .font(.headline)
            .foregroundStyle(.secondary)

          mcpSection
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("OpenAI Secure MCP Tunnel")
            .font(.headline)
            .foregroundStyle(.secondary)

          tunnelSection
        }
      }
      .padding(24)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("连接")
  }

  private var serviceSection: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center) {
          Label("LaunchAgent 进程", systemImage: "server.rack")
            .font(.headline)

          Spacer()

          StatusBadge(registrationLabel, tone: registrationTone)
        }

        HStack {
          Text("本机 XPC 通信：")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          StatusBadge(
            model.connectionState.label, symbol: model.connectionState.symbol, tone: serviceTone)
        }

        switch model.registrationStatus {
        case .notRegistered:
          CalloutBanner(
            title: "后台服务尚未注册",
            message: "注册后台服务后，Codex Bridge 可以在 App 关闭后持续响应已启用的 MCP 客户端并维持任务执行。",
            symbol: "info.circle",
            tone: .info,
            actionTitle: "立即注册后台 Service"
          ) {
            model.registerService()
          }

        case .requiresApproval:
          CalloutBanner(
            title: "等待 macOS 登录项批准",
            message: "系统已登记后台项，请前往“系统设置 → 通用 → 登录项”允许 Codex Bridge 在后台运行。",
            symbol: "exclamationmark.triangle.fill",
            tone: .warning,
            actionTitle: "打开系统设置"
          ) {
            model.openSystemSettings()
          }

        case .notFound:
          CalloutBanner(
            title: "LaunchAgent 配置缺失",
            message: "当前 App Bundle 中未检测到打包的 Service plist 配置，请重新构建项目。",
            symbol: "xmark.circle.fill",
            tone: .error
          )

        case .enabled:
          HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
              .foregroundStyle(.green)
            Text("后台 LaunchAgent 服务正在受监管运行中。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var mcpSection: some View {
    MCPClientConnectionsView(model: model)
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
          CodeSnippetBlock(text: configuredID, label: "已绑定的 Tunnel ID")
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
          Button("保存并启动连接") {
            let key = runtimeKey
            runtimeKey = ""
            model.configureTunnel(tunnelID: tunnelID, runtimeKey: key)
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
              model.clearTunnel()
              tunnelID = ""
              runtimeKey = ""
            }
            .buttonStyle(.bordered)
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

  private var registrationTone: StatusTone {
    switch model.registrationStatus {
    case .enabled: .success
    case .requiresApproval: .warning
    case .notRegistered: .neutral
    case .notFound: .error
    }
  }

  private var tunnelTone: StatusTone {
    if tunnelStatus.lifecycle == "ready" { return .success }
    if tunnelStatus.actionRequired { return .warning }
    if tunnelStatus.enabled { return .running }
    return .neutral
  }

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待系统批准"
    case .notFound: "配置缺失"
    }
  }
}
