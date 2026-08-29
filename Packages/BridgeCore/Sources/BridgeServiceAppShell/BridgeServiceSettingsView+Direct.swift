import SwiftUI
import BridgeServiceAppCore

struct BridgeServiceSettingsDirectApprovalCard: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("MCP Direct 操作审批策略", systemImage: "shield.lefthalf.filled")
            .font(.headline)

          Spacer()

          StatusBadge(
            model.directApprovalMode == "auto" ? "自动批准" : "要求本机批准",
            tone: model.directApprovalMode == "auto" ? .warning : .success
          )
        }

        Toggle(
          "MCP Direct 操作自动批准",
          isOn: Binding(
            get: { model.directApprovalMode == "auto" },
            set: { model.setDirectApprovalMode($0 ? "auto" : "require") }
          )
        )
        .toggleStyle(.switch)

        Text("这是所有 MCP 客户端共享的本机安全策略；关闭时每次文件写操作或终端命令执行均需本机确认，开启时仅对高风险操作阻断。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
