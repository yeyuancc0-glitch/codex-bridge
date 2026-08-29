import SwiftUI
import BridgeServiceAppCore

struct BridgeServiceSettingsView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var showDisableConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "偏好与策略设置",
          subtitle: "配置 AI 模型的默认推理强度、Supervisor 监督、全局安全审批策略与后台常驻服务。",
          icon: "gearshape"
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("模型与执行默认偏好")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          BridgeServiceSettingsCodexDefaultsCard(model: model)

          BridgeServiceSettingsSupervisorDefaultsCard(model: model)

          ForEach(
            ["opencode", "deepseek-harness", "antigravity"],
            id: \.self
          ) { providerID in
            BridgeServiceAgentDefaultsSection(
              model: model,
              providerID: providerID
            )
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("安全策略与全局指令")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          BridgeServiceSettingsDirectApprovalCard(model: model)

          CustomInstructionsEditor(model: model)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("后台运行与远程授权")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          BridgeServiceSettingsBackgroundServiceCard(
            model: model,
            showDisableConfirmation: $showDisableConfirmation
          )
        }
      }
      .padding(28)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("设置")
    .alert("停用后台 Service？", isPresented: $showDisableConfirmation) {
      Button("停用后台服务", role: .destructive) {
        Task { await model.disableBackgroundService() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("停用后，Codex Bridge 的后台 LaunchAgent 守护将被注销，退出 App 将无法继续响应 MCP 远程请求。")
    }
  }

}
