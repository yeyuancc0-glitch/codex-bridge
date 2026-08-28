import SwiftUI

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

          codexDefaultsCard

          supervisorDefaultsCard

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

          directApprovalCard

          CustomInstructionsEditor(model: model)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("后台常驻服务与系统守护")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          backgroundServiceCard
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

  private var codexDefaultsCard: some View {
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
          modelCatalogStatus
        } else if model.modelPreferences == nil {
          ProgressView("正在从 Service 同步模型偏好…")
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Picker("默认模型", selection: executionModelBinding) {
              modelOptions(selectedID: model.modelPreferences?.executionModel)
            }

            Picker("推理强度", selection: executionEffortBinding) {
              effortOptions(
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

  private var supervisorDefaultsCard: some View {
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
          modelCatalogStatus
        } else if model.modelPreferences == nil {
          ProgressView("正在从 Service 同步监督偏好…")
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Picker("监督模型", selection: supervisorModelBinding) {
              modelOptions(selectedID: model.modelPreferences?.supervisorModel)
            }

            Picker("推理强度", selection: supervisorEffortBinding) {
              effortOptions(
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

  private var directApprovalCard: some View {
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

  private var backgroundServiceCard: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("LaunchAgent 系统常驻守护", systemImage: "server.rack")
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
            message: "注册后台服务后，Codex Bridge 可以在 App 关闭后持续响应已启用的 MCP 客户端并维持任务执行。",
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

        Divider()

        HStack(spacing: 12) {
          Button("打开 macOS 登录项设置") {
            model.openSystemSettings()
          }
          .buttonStyle(.bordered)

          if model.registrationStatus == .notRegistered {
            Button("注册后台服务") {
              model.registerService()
            }
            .buttonStyle(.borderedProminent)
          } else if model.registrationStatus == .enabled {
            Button("停用后台服务", role: .destructive) {
              showDisableConfirmation = true
            }
            .buttonStyle(.bordered)
          }
        }

        CalloutBanner(
          title: "生命周期保障说明",
          message:
            "关闭或退出当前可视化 App 只会断开本机 XPC 客户端，不会主动停止后台 Service、Codex 或外部 Provider。只有点击“停用后台服务”才会注销系统 LaunchAgent 守护。",
          symbol: "info.circle",
          tone: .neutral
        )
      }
    }
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

  private var registrationTone: StatusTone {
    switch model.registrationStatus {
    case .enabled: .success
    case .requiresApproval: .warning
    case .notRegistered: .neutral
    case .notFound: .error
    }
  }

  private var serviceTone: StatusTone {
    switch model.connectionState {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle, .unavailable: .error
    }
  }
}

private struct CustomInstructionsEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var draft = ""
  @State private var savedValue = ""

  private let maximumBytes = 32_768

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("全局自定义指令 (Custom Instructions)", systemImage: "text.badge.checkmark")
            .font(.headline)

          Spacer()

          if isWithinLimit && !draft.isEmpty {
            StatusBadge("\(draft.utf8.count) 字节", tone: .neutral)
          }
        }

        if model.customInstructions == nil {
          ProgressView("正在从 Service 读取自定义指令…")
        } else {
          TextEditor(text: $draft)
            .font(.system(size: 13, design: .monospaced))
            .frame(minHeight: 120, maxHeight: 180)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
            )
            .accessibilityLabel("全局自定义指令")

          HStack(alignment: .center) {
            Text(
              "ChatGPT 网页版与 Qwen 会在调用 Codex Bridge 插件前收到该指令（不传给 Codex/Agent 内核）。保存后 Qwen 重新连接即可生效；ChatGPT 还需在插件详情中刷新。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 16)

            Button("保存指令") {
              model.saveCustomInstructions(draft)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
              draft == savedValue || !isWithinLimit || model.isSavingCustomInstructions
            )
          }
        }
      }
    }
    .onAppear { synchronizeDraft(model.customInstructions) }
    .onChange(of: model.customInstructions) { _, value in synchronizeDraft(value) }
  }

  private var isWithinLimit: Bool {
    draft.utf8.count <= maximumBytes
  }

  private func synchronizeDraft(_ value: String?) {
    guard let value, value == draft || draft == savedValue else { return }
    draft = value
    savedValue = value
  }
}
