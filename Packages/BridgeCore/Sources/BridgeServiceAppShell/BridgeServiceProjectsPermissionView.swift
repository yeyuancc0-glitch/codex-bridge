import BridgeMCP
import SwiftUI

struct ProjectPermissionEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  let project: MCPProjectSummary
  @State private var draft: BridgeProjectPolicyDraft
  @State private var showSavedFeedback = false

  init(model: BridgeServiceAppModel, project: MCPProjectSummary) {
    self.model = model
    self.project = project
    _draft = State(initialValue: BridgeProjectPolicyDraft(project: project))
  }

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        VStack(spacing: 12) {
          permissionPickerRow(
            "读取权限",
            symbol: "doc.text.magnifyingglass",
            selection: $draft.readPermission,
            supportsLocalApproval: false
          )
          Divider()
          permissionPickerRow(
            "写入权限", symbol: "pencil.and.outline", selection: $draft.writePermission)
          Divider()
          permissionPickerRow("网络权限", symbol: "network", selection: $draft.networkPermission)
        }

        Divider()

        HStack(spacing: 12) {
          Button("保存权限配置") {
            model.updateProjectPolicy(projectID: project.projectID, draft: draft)
            withAnimation(.easeInOut(duration: 0.2)) {
              showSavedFeedback = true
            }
            Task {
              try? await Task.sleep(for: .seconds(2.5))
              withAnimation(.easeInOut(duration: 0.3)) {
                showSavedFeedback = false
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!hasChanges)

          if showSavedFeedback {
            HStack(spacing: 4) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("权限已保存生效")
                .font(.caption)
                .foregroundStyle(.green)
            }
            .transition(.opacity)
          } else if !hasChanges {
            HStack(spacing: 4) {
              Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
              Text("已是最新生效状态")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Text("安全原则：MCP 客户端和 Supervisor 永远不能代替本机用户批准 Codex 操作。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .onChange(of: project) {
      if !hasChanges {
        draft = BridgeProjectPolicyDraft(project: project)
      }
    }
  }

  private var hasChanges: Bool {
    draft != BridgeProjectPolicyDraft(project: project)
  }

  private func permissionPickerRow(
    _ title: String,
    symbol: String,
    selection: Binding<String>,
    supportsLocalApproval: Bool = true
  ) -> some View {
    HStack(alignment: .center) {
      Label(title, systemImage: symbol)
        .font(.subheadline.weight(.medium))
        .frame(width: 120, alignment: .leading)

      Spacer()

      Picker(title, selection: selection) {
        Text("拒绝").tag("denied")
        if supportsLocalApproval {
          Text("需要本机批准").tag("requiresLocalApproval")
        } else if selection.wrappedValue == "requiresLocalApproval" {
          Text("需批准（不支持）").tag("requiresLocalApproval")
            .disabled(true)
        }
        Text("允许").tag("allowed")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 320)
    }
  }
}
