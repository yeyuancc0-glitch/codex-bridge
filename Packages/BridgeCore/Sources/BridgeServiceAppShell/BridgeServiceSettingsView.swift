import SwiftUI

struct BridgeServiceSettingsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    Form {
      modelDefaultsSection(
        title: "执行任务默认偏好",
        description: "ChatGPT 提交新任务时，若未显式指定模型，将默认使用该配置。"
      )

      modelDefaultsSection(
        title: "Supervisor 只读监督",
        description: "启用后，新任务会启动独立的只读 Supervisor 进行合规与执行监督；Supervisor 无权替本机用户批准操作。",
        supervisor: true
      )

      modelCatalogSection

      Section("后台常驻服务") {
        LabeledContent("当前状态", value: registrationLabel)
        Button("打开 macOS 登录项设置") {
          model.openSystemSettings()
        }
        Button("停用后台 Service", role: .destructive) {
          Task { await model.disableBackgroundService() }
        }
        .disabled(model.registrationStatus == .notRegistered)
      }

      Section("生命周期说明") {
        Text("关闭或退出当前可视化 App 只会断开本机 XPC 客户端，不会主动停止后台 Service、Codex 或 Supervisor。")
          .font(.caption)
        Text("只有在此处点击“停用后台 Service”才会注销系统 LaunchAgent 守护。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding(20)
    .navigationTitle("设置")
  }

  @ViewBuilder
  private func modelDefaultsSection(
    title: String,
    description: String,
    supervisor: Bool = false
  ) -> some View {
    Section {
      if supervisor {
        Toggle("启用 Supervisor 只读监督", isOn: supervisorEnabledBinding)
      }
      if model.models.isEmpty {
        modelCatalogStatus
      } else if model.modelPreferences == nil {
        ProgressView("正在从 Service 同步模型偏好…")
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Picker(
            "默认模型",
            selection: supervisor ? supervisorModelBinding : executionModelBinding
          ) {
            modelOptions(
              selectedID: supervisor
                ? model.modelPreferences?.supervisorModel
                : model.modelPreferences?.executionModel
            )
          }

          Picker(
            "推理强度",
            selection: supervisor ? supervisorEffortBinding : executionEffortBinding
          ) {
            effortOptions(
              modelID: supervisor
                ? model.modelPreferences?.supervisorModel
                : model.modelPreferences?.executionModel,
              selectedEffort: supervisor
                ? model.modelPreferences?.supervisorEffort
                : model.modelPreferences?.executionEffort
            )
          }

          if !supervisor {
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
          }

          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .disabled(supervisor && !(model.modelPreferences?.supervisorEnabled ?? true))
      }
    } header: {
      Text(title)
    }
    .disabled(model.models.isEmpty || model.modelPreferences == nil)
  }

  @ViewBuilder
  private var modelCatalogStatus: some View {
    if let error = model.modelCatalogError {
      VStack(alignment: .leading, spacing: 8) {
        Label("模型目录读取失败", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("重试刷新") {
          model.refresh()
        }
      }
    } else {
      Text("尚未读取到 Codex 模型目录，请确保 Codex app-server 正常运行。")
        .foregroundStyle(.secondary)
    }
  }

  private var modelCatalogSection: some View {
    Section("Codex 本机模型目录") {
      if model.models.isEmpty {
        modelCatalogStatus
      } else {
        ForEach(model.models, id: \.modelID) { item in
          LabeledContent(item.displayName) {
            VStack(alignment: .trailing, spacing: 2) {
              Text(item.modelID)
                .font(.caption.monospaced())
              Text("支持推理强度：" + item.reasoningEfforts.map(reasoningTitle).joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func modelOptions(selectedID: String?) -> some View {
    if let selectedID,
      !model.models.contains(where: { $0.modelID == selectedID })
    {
      Text("当前设置不可用 · \(selectedID)")
        .tag(selectedID)
    }
    ForEach(model.models, id: \.modelID) { item in
      Text("\(item.displayName) · \(item.modelID)")
        .tag(item.modelID)
    }
  }

  @ViewBuilder
  private func effortOptions(modelID: String?, selectedEffort: String?) -> some View {
    let efforts = model.models.first(where: { $0.modelID == modelID })?.reasoningEfforts ?? []
    if let selectedEffort, !efforts.contains(selectedEffort) {
      Text("当前设置不可用 · \(selectedEffort)")
        .tag(selectedEffort)
    }
    ForEach(efforts, id: \.self) { effort in
      Text("\(reasoningTitle(effort)) · \(effort)")
        .tag(effort)
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

  private func reasoningTitle(_ effort: String) -> String {
    switch effort.lowercased() {
    case "minimal": "最低"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh", "extra_high": "极高"
    default: effort
    }
  }

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}
