import AppKit
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
          "连接",
          subtitle: "后台 Service 持有 MCP、Codex 和 Supervisor；关闭 App 不会停止任务。"
        )

        serviceSection
        Divider()
        mcpSection
        Divider()
        tunnelSection
      }
      .padding(24)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .navigationTitle("连接")
  }

  private var serviceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("后台 Service")
        .font(.headline)
      LabeledContent("系统注册", value: registrationLabel)
      LabeledContent("XPC", value: model.connectionState.label)

      switch model.registrationStatus {
      case .notRegistered:
        Button("注册后台 Service") {
          model.registerService()
        }
        .buttonStyle(.borderedProminent)
      case .requiresApproval:
        Label(
          "macOS 已记录后台项目，但需要你在登录项设置中批准。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        Button("打开登录项设置") {
          model.openSystemSettings()
        }
      case .notFound:
        Label(
          "App Bundle 中没有找到 LaunchAgent 配置。请重新构建或安装 App。",
          systemImage: "xmark.circle.fill"
        )
        .foregroundStyle(.red)
      case .enabled:
        Label("后台 Service 已启用。", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
  }

  private var mcpSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("本地 MCP")
        .font(.headline)
      LabeledContent("状态", value: model.serviceStatus?.status.mcpState ?? "未知")
      LabeledContent("工具权限", value: model.exposureMode.localizedTitle)
      if let localMCPURL = model.safeLocalMCPDescription {
        LabeledContent("本机地址") {
          Text(localMCPURL)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        Text(
          "这个地址只供本机诊断，调用时还需要 X-Codex-Bridge-Token Header；本界面不会显示认证 Secret。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Picker(
        "MCP 工具权限",
        selection: Binding(
          get: { model.exposureMode },
          set: { model.setExposureMode($0) }
        )
      ) {
        Text("只读").tag(MCPServiceExposureMode.readOnly)
        Text("完整操作").tag(MCPServiceExposureMode.full)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360)

      Text(
        model.exposureMode == .full
          ? "完整操作会向 ChatGPT 暴露任务提交、纠偏和中断工具；所有任务和 Codex 权限仍需本机批准。"
          : "只读模式只允许查询项目、文件、Thread、模型和任务状态。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var tunnelSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Secure MCP Tunnel")
        .font(.headline)
      LabeledContent("状态", value: tunnelStatus.lifecycle)
      LabeledContent("Helper", value: tunnelStatus.helperAvailable ? "可用" : "未打包")
      LabeledContent(
        "远程任务",
        value: tunnelStatus.acceptsRemoteSubmissions ? "可接收" : "关闭"
      )
      if let configuredID = tunnelStatus.tunnelID {
        LabeledContent("Tunnel ID") {
          Text(configuredID)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }

      if !tunnelStatus.helperAvailable {
        Label(
          "当前 App 构建没有已签名的 tunnel-client helper；本机 MCP 仍可用，但 ChatGPT 无法远程连接。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      }
      if tunnelStatus.actionRequired {
        Label(
          "Tunnel 需要本机处理。请核对 Tunnel ID、Runtime Key 和工作区权限。",
          systemImage: "exclamationmark.shield.fill"
        )
        .foregroundStyle(.orange)
      }

      TextField("tunnel_…", text: $tunnelID)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 520)
      SecureField("Runtime API Key", text: $runtimeKey)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 520)

      HStack {
        Button("保存并连接") {
          let key = runtimeKey
          runtimeKey = ""
          model.configureTunnel(tunnelID: tunnelID, runtimeKey: key)
        }
        .buttonStyle(.borderedProminent)
        .disabled(tunnelID.isEmpty || runtimeKey.isEmpty || !tunnelStatus.helperAvailable)

        if tunnelStatus.configured {
          Button(tunnelStatus.enabled ? "断开" : "重新连接") {
            if tunnelStatus.enabled {
              model.disconnectTunnel()
            } else {
              model.connectTunnel()
            }
          }
          Button("清除配置", role: .destructive) {
            model.clearTunnel()
            tunnelID = ""
            runtimeKey = ""
          }
        }
      }

      Text(
        "Runtime Key 只通过本机 XPC 发送一次并写入 Keychain，不进入 SQLite、日志或状态快照。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
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

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}

struct BridgeServiceSettingsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    Form {
      modelDefaultsSection(
        title: "执行任务",
        description: "ChatGPT 提交的新任务会使用这里的默认值。"
      )
      modelDefaultsSection(
        title: "Supervisor 监督",
        description: "启用后，ChatGPT 提交的新任务会自动启动 Supervisor 只读监督；Supervisor 不会替你批准 Codex 操作。",
        supervisor: true
      )
      modelCatalogSection

      Section("后台运行") {
        LabeledContent("注册状态", value: registrationLabel)
        Button("打开 macOS 登录项设置") {
          model.openSystemSettings()
        }
        Button("停用后台 Service", role: .destructive) {
          Task { await model.disableBackgroundService() }
        }
        .disabled(model.registrationStatus == .notRegistered)
      }

      Section("说明") {
        Text(
          "退出可视化 App 只会断开本机 XPC 客户端，不会主动停止后台 Service、Codex 或 Supervisor。"
        )
        Text(
          "只有“停用后台 Service”属于明确的后台停止操作。正在执行任务时不建议使用。"
        )
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
        Toggle("启用 Supervisor 监督", isOn: supervisorEnabledBinding)
      }
      if model.models.isEmpty {
        modelCatalogStatus
      } else if model.modelPreferences == nil {
        ProgressView("正在读取当前默认值…")
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

          Text(description)
            .font(.caption)
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
        Button("重试") {
          model.refresh()
        }
      }
    } else {
      Text("尚未读取到 Codex 模型目录。")
        .foregroundStyle(.secondary)
    }
  }

  private var modelCatalogSection: some View {
    Section("模型目录") {
      if model.models.isEmpty {
        modelCatalogStatus
      } else {
        ForEach(model.models, id: \.modelID) { item in
          LabeledContent(item.displayName) {
            VStack(alignment: .trailing, spacing: 2) {
              Text(item.modelID)
                .font(.caption.monospaced())
              Text("支持推理强度：" + item.reasoningEfforts.map(reasoningTitle).joined(separator: "、"))
                .font(.caption)
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
