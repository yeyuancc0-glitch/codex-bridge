import SwiftUI

public struct OnboardingView: View {
  @ObservedObject private var store: OnboardingPresentationStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var tunnelID = ""
  @State private var runtimeKey = ""
  @State private var manualEndpoint = ""
  @State private var manualSecret = ""
  @State private var writeDefault = OnboardingPermissionDefault.localApproval
  @State private var networkDefault = OnboardingPermissionDefault.denied

  public init(store: OnboardingPresentationStore) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header
          Divider()
          stepContent
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(32)
      }
      Divider()
      footer
    }
    .frame(minWidth: 640, minHeight: 520)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Codex Bridge 首次设置")
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.16),
      value: store.presentation.currentStep
    )
    .onChange(of: store.presentation.currentStep) { _, step in
      if step == .securityDefaults { synchronizePermissionDrafts() }
      if step == .connectionConfiguration { tunnelID = store.presentation.tunnelID }
    }
    .onAppear {
      tunnelID = store.presentation.tunnelID
      synchronizePermissionDrafts()
    }
    .alert(
      store.actionError?.title ?? "无法继续",
      isPresented: errorBinding,
      presenting: store.actionError
    ) { _ in
      Button("好") { store.dismissError() }
    } message: { error in
      Text(error.message)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Codex Bridge")
          .font(.title2.weight(.semibold))
        Text("BETA")
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        Spacer()
        Text("步骤 \(stepNumber) / \(OnboardingStep.allCases.count)")
          .foregroundStyle(.secondary)
      }
      ProgressView(value: Double(stepNumber), total: Double(OnboardingStep.allCases.count))
        .accessibilityLabel("首次设置进度")
        .accessibilityValue("第 \(stepNumber) 步，共 \(OnboardingStep.allCases.count) 步")
      Text(store.presentation.currentStep.title)
        .font(.largeTitle.weight(.semibold))
      Text(store.presentation.currentStep.detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var stepContent: some View {
    switch store.presentation.currentStep {
    case .welcome:
      welcomeContent
    case .systemCheck:
      systemCheckContent
    case .codexAccount:
      accountContent
    case .connectionMode:
      connectionModeContent
    case .connectionConfiguration:
      connectionConfigurationContent
    case .project:
      projectContent
    case .securityDefaults:
      securityContent
    case .connectionTest:
      connectionTestContent
    case .completion:
      completionContent
    }
  }

  private var welcomeContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("本机优先", systemImage: "macbook.and.iphone")
        .font(.headline)
      Text("Bridge 不运营开发者云服务器。项目路径、审批和任务证据保留在这台 Mac。")
      Label("凭证分工清楚", systemImage: "key")
        .font(.headline)
      Text("Codex 推理由 ChatGPT 官方登录负责；Runtime Key 只用于 Secure Tunnel 传输。")
      Label("所有高风险决定留在本机", systemImage: "hand.raised")
        .font(.headline)
      Text("项目外访问、网络、包安装和写入按策略拒绝或要求本机确认。")
    }
  }

  private var systemCheckContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(store.presentation.checks) { check in
        OnboardingStatusRow(check: check)
        if check.id != store.presentation.checks.last?.id { Divider() }
      }
      Button("重新检测", systemImage: "arrow.clockwise") {
        Task { await store.perform(.runSystemChecks) }
      }
      .padding(.top, 16)
      .disabled(store.presentation.isBusy)
    }
  }

  private var accountContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      OnboardingStatusRow(
        check: OnboardingCheckPresentation(
          id: "account",
          title: store.presentation.account.title,
          detail: store.presentation.account.detail,
          status: store.presentation.account.status
        )
      )
      if store.presentation.account.loginInProgress {
        Button("取消登录", role: .cancel) {
          Task { await store.perform(.cancelCodexLogin) }
        }
      } else if store.presentation.account.status != .ready {
        Button("使用 ChatGPT 登录", systemImage: "person.crop.circle.badge.checkmark") {
          Task { await store.perform(.startCodexLogin) }
        }
        .buttonStyle(.borderedProminent)
      }
      Text("Bridge 只调用 app-server 的账号接口；不会读取 ~/.codex/auth.json。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var connectionModeContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(OnboardingConnectionMode.allCases, id: \.self) { mode in
        Button {
          Task { await store.perform(.selectConnectionMode(mode)) }
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(
              systemName: store.presentation.connectionMode == mode
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              store.presentation.connectionMode == mode ? Color.accentColor : Color.secondary
            )
            VStack(alignment: .leading, spacing: 4) {
              Text(mode.title).font(.headline)
              Text(mode.detail).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .contentShape(Rectangle())
          .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        Divider()
      }
    }
  }

  @ViewBuilder
  private var connectionConfigurationContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch store.presentation.connectionMode {
      case .secureTunnel:
        tunnelConfigurationContent
      case .manualHTTPS:
        manualConfigurationContent
      case .localDevelopment:
        VStack(alignment: .leading, spacing: 12) {
          Label("仅绑定 127.0.0.1", systemImage: "network")
            .font(.headline)
          Text("该模式不会让 ChatGPT 网页获得连接；只用于本机 Inspector 和开发验证。")
            .foregroundStyle(.secondary)
        }
      case nil:
        Text("返回上一步选择连接模式。")
          .foregroundStyle(.secondary)
      }
      if let localURL = store.presentation.localMCPURLDescription {
        VStack(alignment: .leading, spacing: 6) {
          Text("本地 MCP Endpoint")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(localURL)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
          if store.presentation.connectionMode == .manualHTTPS
            || store.presentation.connectionMode == .localDevelopment
          {
            Button("复制完整本机 Endpoint", systemImage: "doc.on.doc") {
              Task { await store.perform(.copyLocalMCPEndpoint) }
            }
            Text("完整地址包含本机认证 Secret；只在你明确复制时进入剪贴板。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var tunnelConfigurationContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("Tunnel ID", text: $tunnelID)
        .textFieldStyle(.roundedBorder)
      SecureField(
        store.presentation.hasStoredRuntimeKey
          ? "Runtime Key 已保存；留空表示不替换" : "Restricted Runtime Key",
        text: $runtimeKey
      )
      .textFieldStyle(.roundedBorder)
      Text("Runtime Key 只写入本机 Keychain，不会进入配置文件、日志、Codex 或 Luna。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("保存 Tunnel 配置", systemImage: "key.fill") {
        let key = runtimeKey
        runtimeKey = ""
        Task {
          await store.perform(
            .saveTunnelConfiguration(
              tunnelID: tunnelID,
              runtimeKey: key
            )
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.presentation.isBusy)
    }
  }

  private var manualConfigurationContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("https://bridge.example.com/mcp", text: $manualEndpoint)
        .textFieldStyle(.roundedBorder)
      SecureField("Authorization 请求头值（例如 Bearer …）", text: $manualSecret)
        .textFieldStyle(.roundedBorder)
      Text("Bridge 会拒绝 HTTP、无认证端点以及未通过 MCP initialize/tools 检查的地址。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("保存 HTTPS 配置", systemImage: "lock.shield") {
        let secret = manualSecret
        manualSecret = ""
        Task {
          await store.perform(
            .saveManualHTTPSConfiguration(
              endpoint: manualEndpoint,
              authenticationSecret: secret
            )
          )
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var projectContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let projectName = store.presentation.projectName {
        Label(projectName, systemImage: "folder.fill.badge.checkmark")
          .font(.headline)
        Text("项目根已登记；远程工具只会看到不可猜测的 project_id。")
          .foregroundStyle(.secondary)
      } else {
        Text("选择一个项目根目录。Bridge 会规范化路径并保存 device/inode 身份。")
          .foregroundStyle(.secondary)
      }
      Button(
        store.presentation.projectName == nil ? "选择项目目录" : "选择其他项目",
        systemImage: "folder.badge.plus"
      ) {
        Task { await store.perform(.addProject) }
      }
    }
  }

  private var securityContent: some View {
    Form {
      Picker("项目写入", selection: $writeDefault) {
        ForEach(OnboardingPermissionDefault.allCases, id: \.self) { value in
          Text(value.title).tag(value)
        }
      }
      Picker("网络访问", selection: $networkDefault) {
        ForEach(OnboardingPermissionDefault.allCases, id: \.self) { value in
          Text(value.title).tag(value)
        }
      }
      Text("生产迁移、凭证读取、系统写入和高风险删除始终直接拒绝，不能被此处放宽。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("保存安全默认值") {
        Task {
          await store.perform(
            .setSecurityDefaults(write: writeDefault, network: networkDefault)
          )
        }
      }
    }
    .formStyle(.grouped)
  }

  private var connectionTestContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      OnboardingStatusRow(check: store.presentation.connectionStatus)
      Button("运行连接测试", systemImage: "checkmark.shield") {
        Task { await store.perform(.testConnection) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.presentation.isBusy)
    }
  }

  private var completionContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("首次设置已通过", systemImage: "checkmark.seal.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.green)
      Text("主窗口会显示真实连接、项目和任务状态。你可以随时在“连接”与“设置”中重新检查。")
      Text("ChatGPT 网页不能被本机主动唤醒；任务结果通过 MCP 查询读取。")
        .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack {
      Button("返回") {
        Task { await store.perform(.goBack) }
      }
      .disabled(!store.presentation.canGoBack || store.presentation.isBusy)
      Spacer()
      if store.presentation.isBusy { ProgressView().controlSize(.small) }
      Button(store.presentation.primaryActionTitle) {
        Task {
          let action: OnboardingAction =
            store.presentation.currentStep == .completion ? .finish : .advance
          _ = await store.perform(action)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!store.presentation.canContinue || store.presentation.isBusy)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  private var stepNumber: Int {
    store.presentation.currentStep.rawValue + 1
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.actionError != nil },
      set: { value in
        if !value { store.dismissError() }
      }
    )
  }

  private func synchronizePermissionDrafts() {
    writeDefault = store.presentation.writeDefault
    networkDefault = store.presentation.networkDefault
  }
}

private struct OnboardingStatusRow: View {
  let check: OnboardingCheckPresentation

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if check.status == .checking {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: check.status.systemImage)
          .foregroundStyle(statusColor)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(check.title).font(.headline)
        Text(check.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }

  private var statusColor: Color {
    switch check.status {
    case .ready: .green
    case .warning: .orange
    case .blocked: .red
    case .pending, .checking: .secondary
    }
  }
}
