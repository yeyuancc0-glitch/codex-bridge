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
          "连接与服务",
          subtitle: "后台 LaunchAgent Service 持有 MCP 与 Secure Tunnel，关闭可视化 App 不会停止任务。",
          icon: "point.3.connected.trianglepath.dotted"
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("后台守护服务 (Service)")
            .font(.headline)
            .foregroundStyle(.secondary)

          serviceSection
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("本地 MCP 通道")
            .font(.headline)
            .foregroundStyle(.secondary)

          mcpSection
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("OpenAI Secure MCP Tunnel")
            .font(.headline)
            .foregroundStyle(.secondary)

          tunnelSection
        }
      }
      .padding(24)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("连接")
  }

  private var serviceSection: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center) {
          Label("LaunchAgent 进程", systemImage: "server.rack")
            .font(.headline)

          Spacer()

          StatusBadge(registrationLabel, tone: registrationTone)
        }

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
            message: "注册后台服务后，Codex Bridge 可以在 App 关闭后持续响应 ChatGPT 并维持任务执行。",
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
      }
    }
  }

  private var mcpSection: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("MCP 接口状态", systemImage: "network.badge.shield.half.filled")
            .font(.headline)

          Spacer()

          StatusBadge(
            model.serviceStatus?.status.mcpState ?? "未知",
            tone: model.serviceStatus?.status.mcpState == "ready" ? .success : .neutral
          )
        }

        if let localMCPURL = model.safeLocalMCPDescription {
          CodeSnippetBlock(text: localMCPURL, label: "本机回环诊断端点 (需认证 Header)")

          Text("该地址仅供本机进程与诊断使用，调用必须携带 X-Codex-Bridge-Token；不会向外泄露认证 Secret。")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          Text("MCP 工具暴露模式")
            .font(.subheadline.weight(.medium))

          Picker(
            "MCP 工具权限",
            selection: Binding(
              get: { model.exposureMode },
              set: { model.setExposureMode($0) }
            )
          ) {
            Text("只读模式 (仅查询)").tag(MCPServiceExposureMode.readOnly)
            Text("完整操作 (任务提交与干预)").tag(MCPServiceExposureMode.full)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 420)

          Text(
            model.exposureMode == .full
              ? "完整模式会向 ChatGPT 暴露：Codex 任务提交/纠偏/中断，以及用户明确要求直接执行时的 ChatGPT Direct 文件编辑与受控命令执行。所有危险写入与执行仍需本机授权。"
              : "只读模式仅允许 ChatGPT 读取项目目录结构、文件内容、Thread、任务状态与已登记命令清单。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var tunnelSection: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Secure MCP 隧道", systemImage: "link.icloud.fill")
            .font(.headline)

          Spacer()

          StatusBadge(tunnelStatus.lifecycle, tone: tunnelTone)
        }

        HStack(spacing: 16) {
          HStack(spacing: 4) {
            Text("Helper 辅助工具：")
              .font(.caption)
              .foregroundStyle(.secondary)
            StatusBadge(
              tunnelStatus.helperAvailable ? "就绪" : "未打包",
              tone: tunnelStatus.helperAvailable ? .success : .warning)
          }

          HStack(spacing: 4) {
            Text("远程任务接收：")
              .font(.caption)
              .foregroundStyle(.secondary)
            StatusBadge(
              tunnelStatus.acceptsRemoteSubmissions ? "允许" : "关闭",
              tone: tunnelStatus.acceptsRemoteSubmissions ? .success : .neutral)
          }
        }

        if let configuredID = tunnelStatus.tunnelID, !configuredID.isEmpty {
          CodeSnippetBlock(text: configuredID, label: "已绑定的 Tunnel ID")
        }

        if !tunnelStatus.helperAvailable {
          CalloutBanner(
            title: "Helper 辅助工具缺失",
            message: "App 构建中未发现已签名的 tunnel-client 辅助二进制，本机 MCP 可用但无法进行远程隧道连接。",
            symbol: "exclamationmark.triangle.fill",
            tone: .warning
          )
        }

        if tunnelStatus.actionRequired {
          CalloutBanner(
            title: "需要检查 Tunnel 凭据",
            message: "Tunnel 报告需要本机处理，请核对 Tunnel ID、Runtime Key 以及当前工作区权限。",
            symbol: "exclamationmark.shield.fill",
            tone: .warning
          )
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("配置或更新凭据")
            .font(.subheadline.weight(.medium))

          TextField("OpenAI Tunnel ID (例如: tunnel_...)", text: $tunnelID)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 540)

          SecureField("Runtime API Key", text: $runtimeKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 540)
        }

        HStack(spacing: 12) {
          Button("保存并启动连接") {
            let key = runtimeKey
            runtimeKey = ""
            model.configureTunnel(tunnelID: tunnelID, runtimeKey: key)
          }
          .buttonStyle(.borderedProminent)
          .disabled(tunnelID.isEmpty || runtimeKey.isEmpty || !tunnelStatus.helperAvailable)

          if tunnelStatus.configured {
            Button(tunnelStatus.enabled ? "断开隧道" : "重新连接") {
              if tunnelStatus.enabled {
                model.disconnectTunnel()
              } else {
                model.connectTunnel()
              }
            }
            .buttonStyle(.bordered)

            Button("清除配置", role: .destructive) {
              model.clearTunnel()
              tunnelID = ""
              runtimeKey = ""
            }
            .buttonStyle(.bordered)
          }
        }

        Text("安全保障：Runtime Key 只通过本机内存 XPC 发送一次并存入 macOS Keychain，绝不写入 SQLite、日志或导出文件。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
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

  private var serviceTone: StatusTone {
    switch model.connectionState {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle, .unavailable: .error
    }
  }

  private var registrationTone: StatusTone {
    switch model.registrationStatus {
    case .enabled: .success
    case .requiresApproval: .warning
    case .notRegistered: .neutral
    case .notFound: .error
    }
  }

  private var tunnelTone: StatusTone {
    if tunnelStatus.lifecycle == "ready" { return .success }
    if tunnelStatus.actionRequired { return .warning }
    if tunnelStatus.enabled { return .running }
    return .neutral
  }

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待系统批准"
    case .notFound: "配置缺失"
    }
  }
}

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
