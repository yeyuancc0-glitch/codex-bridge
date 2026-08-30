import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceSettingsBackgroundServiceCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  @Binding var showDisableConfirmation: Bool

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("后台运行与远程 Agent 授权", systemImage: "server.rack")
            .font(.headline)
        }

        Toggle(
          "自动批准远程 Agent 启动请求",
          isOn: Binding(
            get: { model.taskStartApprovalMode == "auto" },
            set: { model.setTaskStartApprovalMode($0 ? "auto" : "require") }
          )
        )
        .toggleStyle(.switch)
        .disabled(model.connectionState != .connected)

        Text(
          "默认关闭。开启后，ChatGPT 或 Qwen 提交的 Codex、OpenCode、DeepSeek Harness、Antigravity 任务无需逐次本机批准即可启动；Provider 工具审批和 Direct 高风险操作仍遵循各自策略。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        Toggle(
          "退出 App 后保持后台服务运行",
          isOn: $model.keepServiceRunningAfterAppExit
        )
        .toggleStyle(.switch)

        Text(
          model.keepServiceRunningAfterAppExit
            ? "退出可视化 App 后，LaunchAgent、远程 MCP 连接和进行中的任务继续运行。"
            : "按 ⌘Q 退出 App 时将注销 LaunchAgent，并停止远程连接和进行中的任务。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

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
            message:
              model.keepServiceRunningAfterAppExit
              ? "注册后台服务后，Codex Bridge 可以在 App 退出后持续响应已启用的 MCP 客户端并维持任务执行。"
              : "注册后台服务后，Codex Bridge 会在 App 打开期间响应已启用的 MCP 客户端；按 ⌘Q 退出时停止。",
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

        Divider()

        HStack(spacing: 12) {
          Button("打开 macOS 登录项设置") {
            model.openSystemSettings()
          }
          .buttonStyle(.bordered)

          if model.registrationStatus == .notRegistered {
            Button("注册后台服务") {
              model.registerService()
            }
            .buttonStyle(.borderedProminent)
          } else if model.registrationStatus == .enabled {
            Button("停用后台服务", role: .destructive) {
              showDisableConfirmation = true
            }
            .buttonStyle(.bordered)
          }
        }

        CalloutBanner(
          title: "生命周期保障说明",
          message:
            model.keepServiceRunningAfterAppExit
            ? "关闭窗口不影响 App 与后台 Service；退出 App 只断开本机 XPC 客户端，不会停止 Codex 或外部 Provider。"
            : "关闭窗口不会停止后台 Service；按 ⌘Q 退出 App 时会注销 LaunchAgent 并停止 Codex 或外部 Provider。",
          symbol: "info.circle",
          tone: .neutral
        )
      }
    }
  }

  private var serviceTone: StatusTone {
    switch model.connectionState {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle, .unavailable: .error
    }
  }
}
