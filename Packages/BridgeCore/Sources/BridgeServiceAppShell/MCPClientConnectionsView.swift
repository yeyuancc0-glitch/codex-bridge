import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import SwiftUI

struct MCPClientConnectionsView: View {
  private enum Confirmation: String, Identifiable {
    case rotateCredential
    case rotateEndpoint

    var id: String { rawValue }
  }

  @ObservedObject var model: BridgeServiceAppModel
  @State private var confirmation: Confirmation?
  @State private var isCopyingQwen = false

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 16) {
        serviceHeader
        endpoint
        Divider()
        clientRow(chatGPTProfile, isQwen: false)
        Divider()
        clientRow(qwenProfile, isQwen: true)
      }
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }
      ),
      titleVisibility: .visible,
      presenting: confirmation
    ) { value in
      switch value {
      case .rotateCredential:
        Button("重新生成 Qwen 凭证", role: .destructive) {
          model.rotateQwenStudioCredential()
        }
      case .rotateEndpoint:
        Button("重新生成 Endpoint", role: .destructive) {
          model.rotateLocalMCPEndpoint()
        }
      }
      Button("取消", role: .cancel) {}
    } message: { value in
      Text(confirmationMessage(value))
    }
  }

  private var serviceHeader: some View {
    HStack {
      Label("本地 MCP 客户端通道", systemImage: "network.badge.shield.half.filled")
        .font(.headline)
      Spacer()
      StatusBadge(
        model.serviceStatus?.status.mcpState ?? "未知",
        tone: model.serviceStatus?.status.mcpState == "ready" ? .success : .neutral
      )
    }
  }

  @ViewBuilder
  private var endpoint: some View {
    if let localMCPURL = model.safeLocalMCPDescription {
      CodeSnippetBlock(text: localMCPURL, label: "稳定本机 Endpoint (需认证 Header)") {
        model.postToast("已复制本地 MCP Endpoint")
      }
      HStack {
        Text("仅监听 127.0.0.1；凭证由 macOS Keychain 管理，不进明文状态或 SQLite。")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("重新生成 Endpoint") { confirmation = .rotateEndpoint }
          .buttonStyle(.bordered)
      }
    } else if model.serviceStatus?.status.mcpState == "local_port_unavailable" {
      CalloutBanner(
        title: "本地 MCP 端口被占用",
        message: model.serviceStatus?.status.degradations.last
          ?? "已保存的端口无法绑定。不会静默更换地址；可主动生成新的 Endpoint。",
        symbol: "exclamationmark.triangle.fill",
        tone: .warning,
        actionTitle: "重新生成 Endpoint"
      ) {
        confirmation = .rotateEndpoint
      }
    }
  }

  private func clientRow(_ profile: IPCMCPClientStatus, isQwen: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(profile.displayName)
          .font(.subheadline.weight(.semibold))
        StatusBadge(profile.enabled ? "已启用" : "已停用", tone: profile.enabled ? .success : .neutral)
        Spacer()
        Text("活动 Session：\(profile.activeSessionCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if isQwen {
        Toggle(
          "启用 Qwen Studio",
          isOn: Binding(
            get: { profile.enabled },
            set: model.setQwenStudioEnabled
          )
        )
        .toggleStyle(.switch)
      }

      Picker(
        "\(profile.displayName) 工具权限",
        selection: Binding(
          get: { profile.exposureMode },
          set: { mode in
            if isQwen {
              model.setQwenStudioExposureMode(mode)
            } else {
              model.setExposureMode(mode)
            }
          }
        )
      ) {
        Text("只读").tag(MCPServiceExposureMode.readOnly)
        Text("完整").tag(MCPServiceExposureMode.full)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 420)
      .disabled(!profile.enabled)

      Text(
        profile.exposureMode == .full
          ? "向该客户端暴露 Codex 任务与 Direct 工具；项目权限、workspace gate 与本机安全审批仍然生效。"
          : "仅暴露项目、文件、任务、Thread、模型与 Skill 查询工具。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if isQwen {
        HStack(spacing: 10) {
          Button {
            model.copyQwenStudioConfiguration()
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
              isCopyingQwen = true
            }
            Task {
              try? await Task.sleep(for: .seconds(2))
              withAnimation(.easeInOut(duration: 0.2)) {
                isCopyingQwen = false
              }
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: isCopyingQwen ? "checkmark" : "doc.on.doc")
              Text(isCopyingQwen ? "已复制 JSON 配置" : "复制 Qwen JSON 配置")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!profile.enabled)

          Button("重新生成凭证", role: .destructive) {
            confirmation = .rotateCredential
          }
          .buttonStyle(.bordered)
          .disabled(!profile.enabled)
        }
        Text("复制内容包含本机访问凭证；请直接粘贴到 Qwen Studio 的“使用 JSON 添加”，不要保存到公开文档或 Git。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var chatGPTProfile: IPCMCPClientStatus {
    model.mcpClients.first { $0.clientID == MCPClientID.chatGPT.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.chatGPT.rawValue,
        displayName: "ChatGPT / OpenAI Tunnel",
        enabled: true,
        exposureMode: model.exposureMode,
        activeSessionCount: 0
      )
  }

  private var qwenProfile: IPCMCPClientStatus {
    model.mcpClients.first { $0.clientID == MCPClientID.qwenStudio.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.qwenStudio.rawValue,
        displayName: "Qwen Studio",
        enabled: false,
        exposureMode: .readOnly,
        activeSessionCount: 0
      )
  }

  private var confirmationTitle: String {
    confirmation == .rotateEndpoint ? "重新生成本地 Endpoint？" : "重新生成 Qwen 凭证？"
  }

  private func confirmationMessage(_ value: Confirmation) -> String {
    switch value {
    case .rotateCredential:
      "Qwen Studio 中现有配置会立即失效，需要重新复制 JSON。ChatGPT 凭证和 Session 不受影响。"
    case .rotateEndpoint:
      "Qwen Studio 保存的旧 URL 会失效，需要重新复制 JSON；OpenAI Tunnel 会由后台 Service 使用新地址恢复。"
    }
  }
}
