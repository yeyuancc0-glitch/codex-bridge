import BridgeMCP
import BridgeServiceAppCore
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
        VStack(alignment: .leading, spacing: 14) {
          permissionPickerRow(
            "读取权限",
            description: readPermissionDescription,
            symbol: "doc.text.magnifyingglass",
            selection: $draft.readPermission,
            supportsLocalApproval: false
          )
          Divider()
          permissionPickerRow(
            "写入权限",
            description: writePermissionDescription,
            symbol: "pencil.and.outline",
            selection: $draft.writePermission
          )
          Divider()
          permissionPickerRow(
            "网络权限",
            description: networkPermissionDescription,
            symbol: "network",
            selection: $draft.networkPermission
          )
        }

        Divider()

        HStack(spacing: 14) {
          Button {
            model.updateProjectPolicy(projectID: project.projectID, draft: draft)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
              showSavedFeedback = true
            }
            Task {
              try? await Task.sleep(for: .seconds(2.5))
              withAnimation(.easeInOut(duration: 0.3)) {
                showSavedFeedback = false
              }
            }
          } label: {
            HStack(spacing: 6) {
              if showSavedFeedback {
                Image(systemName: "checkmark")
              }
              Text("保存权限配置")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!hasChanges)

          SaveFeedbackBadge(
            showSaved: showSavedFeedback,
            isModified: hasChanges,
            savedText: "权限已保存生效",
            unmodifiedText: "已是最新生效状态"
          )
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

  private var readPermissionDescription: String {
    draft.readPermission == "allowed" ? "允许读取项目内的非敏感代码和文件。" : "禁止读取任何文件。"
  }

  private var writePermissionDescription: String {
    switch draft.writePermission {
    case "allowed": "允许直接创建或修改文件。"
    case "requiresLocalApproval": "每次写操作均需本机用户在 App 中显式确认。"
    default: "禁止创建或修改项目内任何文件。"
    }
  }

  private var networkPermissionDescription: String {
    switch draft.networkPermission {
    case "allowed": "允许执行联网命令或外部请求。"
    case "requiresLocalApproval": "每次尝试联网操作均需本机用户批准。"
    default: "项目策略禁止网络连接。"
    }
  }

  private func permissionPickerRow(
    _ title: String,
    description: String,
    symbol: String,
    selection: Binding<String>,
    supportsLocalApproval: Bool = true
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center) {
        Label(title, systemImage: symbol)
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 130, alignment: .leading)

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

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 26)
    }
  }
}
