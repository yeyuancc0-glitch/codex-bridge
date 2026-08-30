import SwiftUI

struct BridgeServiceSettingsSupervisorDefaultsCard: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Supervisor 只读监督", systemImage: "eye.fill")
            .font(.headline)

          Spacer()

          Toggle(
            "启用",
            isOn: supervisorEnabledBinding
          )
          .toggleStyle(.switch)
        }

        if model.models.isEmpty {
          BridgeServiceSettingsModelCatalogStatus(model: model)
        } else if model.modelPreferences == nil {
          ProgressView("正在从 Service 同步监督偏好…")
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Picker("监督模型", selection: supervisorModelBinding) {
              BridgeServiceSettingsModelOptions(
                model: model,
                selectedID: model.modelPreferences?.supervisorModel
              )
            }

            Picker("推理强度", selection: supervisorEffortBinding) {
              BridgeServiceSettingsEffortOptions(
                model: model,
                modelID: model.modelPreferences?.supervisorModel,
                selectedEffort: model.modelPreferences?.supervisorEffort
              )
            }

            Text("启用后，新任务会启动独立的只读 Supervisor 进行合规与执行监督；Supervisor 无权替本机用户批准操作。")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .disabled(!(model.modelPreferences?.supervisorEnabled ?? true))
        }
      }
    }
  }

  private var supervisorModelBinding: Binding<String> {
    Binding(
      get: { model.modelPreferences?.supervisorModel ?? "" },
      set: { model.setSupervisorModel($0) }
    )
  }

  private var supervisorEffortBinding: Binding<String> {
    Binding(
      get: { model.modelPreferences?.supervisorEffort ?? "" },
      set: { model.setSupervisorEffort($0) }
    )
  }

  private var supervisorEnabledBinding: Binding<Bool> {
    Binding(
      get: { model.modelPreferences?.supervisorEnabled ?? true },
      set: { model.setSupervisorEnabled($0) }
    )
  }
}
