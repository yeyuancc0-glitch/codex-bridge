import SwiftUI

struct BridgeServiceSettingsCodexDefaultsCard: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Codex 执行默认偏好", systemImage: "cpu.fill")
            .font(.headline)

          Spacer()

          if let executionModel = model.modelPreferences?.executionModel, !executionModel.isEmpty {
            StatusBadge(executionModel, tone: .neutral)
          }
        }

        if model.models.isEmpty {
          BridgeServiceSettingsModelCatalogStatus(model: model)
        } else if model.modelPreferences == nil {
          ProgressView("正在从 Service 同步模型偏好…")
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Picker("默认模型", selection: executionModelBinding) {
              BridgeServiceSettingsModelOptions(
                model: model,
                selectedID: model.modelPreferences?.executionModel
              )
            }

            Picker("推理强度", selection: executionEffortBinding) {
              BridgeServiceSettingsEffortOptions(
                model: model,
                modelID: model.modelPreferences?.executionModel,
                selectedEffort: model.modelPreferences?.executionEffort
              )
            }

            Picker("访问权限", selection: accessModeBinding) {
              accessModeOptions(selected: model.modelPreferences?.accessMode)
            }

            Text(accessModeDescription)
              .font(.caption)
              .foregroundStyle(.secondary)

            Toggle("Fast 极速模式", isOn: fastModeBinding)
              .disabled(!fastModeSupported)
            if !fastModeSupported {
              Text("当前选中的默认模型不支持 Fast 模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("MCP 客户端提交新任务时，若未显式指定模型，将默认使用该配置。")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var executionModelBinding: Binding<String> {
    Binding(
      get: { model.modelPreferences?.executionModel ?? "" },
      set: { model.setExecutionModel($0) }
    )
  }

  private var executionEffortBinding: Binding<String> {
    Binding(
      get: { model.modelPreferences?.executionEffort ?? "" },
      set: { model.setExecutionEffort($0) }
    )
  }

  private var accessModeBinding: Binding<String> {
    Binding(
      get: { model.modelPreferences?.accessMode ?? "request-approval" },
      set: { model.setAccessMode($0) }
    )
  }

  private var fastModeBinding: Binding<Bool> {
    Binding(
      get: { model.modelPreferences?.fastModeEnabled ?? false },
      set: { model.setFastMode($0) }
    )
  }

  private var fastModeSupported: Bool {
    let modelID = model.modelPreferences?.executionModel
    return model.models.first(where: { $0.modelID == modelID })?
      .supportsFastMode == true
  }

  @ViewBuilder
  private func accessModeOptions(selected: String?) -> some View {
    let known = ["request-approval", "auto-review", "full-access"]
    if let selected, !known.contains(selected) {
      Text("当前设置不可用 · \(selected)")
        .tag(selected)
    }
    Text("请求批准 (推荐)").tag("request-approval")
    Text("自动评审 (auto-review)").tag("auto-review")
    Text("完全访问权限 (full-access)").tag("full-access")
  }

  private var accessModeDescription: String {
    switch model.modelPreferences?.accessMode {
    case "auto-review":
      "仅对检测到的高风险写操作请求本机批准。"
    case "full-access":
      "可不受限制地访问互联网和受权目录文件。"
    default:
      "编辑项目文件和使用外部工具时始终询问本机批准。"
    }
  }
}
