import SwiftUI

struct TasksPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      HStack(alignment: .firstTextBaseline) {
        PageHeader(
          title: "任务",
          subtitle: "按事实状态检查任务，进入详情读取控制与证据",
          refreshAction: { await store.perform(.refresh(.tasks)) }
        )
        Button("新建只读任务", systemImage: "plus") {
          Task {
            await store.perform(.prepareReadOnlyTask(projectID: nil, threadID: nil))
          }
        }
        .help("从当前 Codex 模型目录准备一个禁网、只读的本机任务")
      }
      LoadStateView(
        state: store.snapshot.tasks,
        retry: { await store.perform(.refresh(.tasks)) }
      ) { page in
        TaskPageContent(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct TaskPageContent: View {
  let page: TaskPagePresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      if let composer = page.readOnlyComposer {
        LoadStateView(
          state: composer,
          retry: {
            await store.perform(.prepareReadOnlyTask(projectID: nil, threadID: nil))
          }
        ) { value in
          ReadOnlyTaskComposer(composer: value, store: store)
        }
        Divider()
      }
      TaskWorkspace(page: page, store: store)
    }
  }
}

private struct ReadOnlyTaskComposer: View {
  let composer: ReadOnlyTaskComposerPresentation
  @ObservedObject var store: BridgePresentationStore
  @State private var projectID: String
  @State private var goal = ""
  @State private var criteria = ""
  @State private var executionModel: String
  @State private var executionEffort: String
  @State private var useSemanticSupervision: Bool
  @State private var supervisorModel: String
  @State private var supervisorEffort: String

  init(composer: ReadOnlyTaskComposerPresentation, store: BridgePresentationStore) {
    self.composer = composer
    self.store = store
    let execution =
      composer.executionModels.first(where: \.isDefault)
      ?? composer.executionModels.first
    let supervisor = composer.supervisorModels.first
    _projectID = State(initialValue: composer.initialProjectID)
    _executionModel = State(initialValue: execution?.id ?? "")
    _executionEffort = State(initialValue: execution?.preferredEffort ?? "")
    _useSemanticSupervision = State(initialValue: composer.supervisorAvailable)
    _supervisorModel = State(initialValue: supervisor?.id ?? "")
    _supervisorEffort = State(initialValue: supervisor?.preferredEffort ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
          Text("本机只读任务")
            .font(.headline)
          Text("只读 · 禁止网络 · 提交后进入现有持久化任务流水线")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("取消") {
          Task { await store.perform(.dismissReadOnlyTask) }
        }
        .disabled(composer.isSubmitting)
        Button("提交") {
          Task { await submit() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      if let blocker = composer.blocker {
        Label(blocker, systemImage: "hand.raised.fill")
          .foregroundStyle(.orange)
          .accessibilityLabel("安全阻断：\(blocker)")
      }
      if !composer.supervisorAvailable {
        Label(
          "Supervisor 当前不可用；关闭语义监督后将使用确定性 Policy Engine，最终报告会标注用户选择。",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
        .accessibilityLabel("监督降级：Supervisor 当前不可用，将使用确定性 Policy Engine")
      }
      HStack(alignment: .top, spacing: BridgeTheme.spacingSection) {
        VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
          Picker("项目", selection: $projectID) {
            ForEach(composer.projects) { project in
              Text(project.name).tag(project.id)
            }
          }
          .disabled(composer.threadID != nil)
          if let threadID = composer.threadID {
            MetadataRow(label: "Thread", value: threadID, monospaced: true)
          } else {
            MetadataRow(label: "Thread", value: "创建新 Thread")
          }
          Text("任务目标")
            .font(.subheadline.weight(.semibold))
          TextEditor(text: $goal)
            .frame(minHeight: 72)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
          Text("验收标准（每行一项）")
            .font(.subheadline.weight(.semibold))
          TextEditor(text: $criteria)
            .frame(minHeight: 72)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
        }
        VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
          Picker("Execution 模型", selection: executionModelBinding) {
            ForEach(composer.executionModels) { model in
              Text(model.displayName).tag(model.id)
            }
          }
          Picker("Execution effort", selection: $executionEffort) {
            ForEach(executionEfforts, id: \.self) { effort in
              Text(effort).tag(effort)
            }
          }
          Toggle("启用语义监督", isOn: $useSemanticSupervision)
            .disabled(!composer.supervisorAvailable)
          Picker(supervisorPickerTitle, selection: supervisorModelBinding) {
            ForEach(composer.supervisorModels) { model in
              Text(model.displayName).tag(model.id)
            }
          }
          .help(supervisorPickerHelp)
          .disabled(!useSemanticSupervision)
          Picker("Supervisor effort", selection: $supervisorEffort) {
            ForEach(supervisorEfforts, id: \.self) { effort in
              Text(effort).tag(effort)
            }
          }
          .disabled(!useSemanticSupervision)
          MetadataRow(label: "权限", value: "read-only（固定）")
          MetadataRow(label: "网络", value: "关闭（固定）")
        }
        .frame(minWidth: 260, maxWidth: 340)
      }
      if composer.isSubmitting {
        ProgressView("正在持久化任务契约")
          .controlSize(.small)
      }
    }
    .padding(BridgeTheme.spacingSection)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }

  private var executionEfforts: [String] {
    composer.executionModels.first(where: { $0.id == executionModel })?.efforts ?? []
  }

  private var supervisorEfforts: [String] {
    composer.supervisorModels.first(where: { $0.id == supervisorModel })?.efforts ?? []
  }

  private var supervisorPickerTitle: String {
    if let recommendation = composer.supervisorRecommendation {
      return "Supervisor 模型（推荐 " + recommendation + "）"
    }
    return "Supervisor 模型（从当前目录选择）"
  }

  private var supervisorPickerHelp: String {
    if composer.supervisorRecommendation != nil {
      return "Luna 是当前目录中的默认推荐项；也可以选择其他可用模型。"
    }
    return "当前目录没有 Luna；请选择一个当前可用的 Supervisor 模型。"
  }

  private var executionModelBinding: Binding<String> {
    Binding(
      get: { executionModel },
      set: { value in
        executionModel = value
        executionEffort =
          composer.executionModels.first(where: { $0.id == value })?.preferredEffort ?? ""
      }
    )
  }

  private var supervisorModelBinding: Binding<String> {
    Binding(
      get: { supervisorModel },
      set: { value in
        supervisorModel = value
        supervisorEffort =
          composer.supervisorModels.first(where: { $0.id == value })?.preferredEffort ?? ""
      }
    )
  }

  private var acceptanceCriteria: [String] {
    criteria.split(whereSeparator: \.isNewline).map(String.init)
  }

  private var canSubmit: Bool {
    composer.blocker == nil && !composer.isSubmitting
      && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !acceptanceCriteria.isEmpty
      && composer.projects.contains(where: { $0.id == projectID })
      && (composer.threadID == nil || projectID == composer.initialProjectID)
      && executionEfforts.contains(executionEffort)
      && (!useSemanticSupervision || supervisorEfforts.contains(supervisorEffort))
  }

  private func submit() async {
    await store.perform(
      .submitReadOnlyTask(
        ReadOnlyTaskDraftPresentation(
          requestID: composer.requestID,
          projectID: projectID,
          threadID: composer.threadID,
          goal: goal,
          acceptanceCriteria: acceptanceCriteria,
          executionModel: executionModel,
          executionEffort: executionEffort,
          supervisorEnabled: useSemanticSupervision,
          supervisorModel: supervisorModel,
          supervisorEffort: supervisorEffort
        )
      )
    )
  }
}

private struct TaskWorkspace: View {
  let page: TaskPagePresentation
  @ObservedObject var store: BridgePresentationStore
  @State private var compactPath: [String] = []

  @ViewBuilder
  var body: some View {
    if page.tasks.isEmpty {
      ContentUnavailableView(
        "暂无任务",
        systemImage: "checklist",
        description: Text("从 ChatGPT 提交任务后会显示在这里。")
      )
    } else {
      ViewThatFits(in: .horizontal) {
        wideWorkspace
          .frame(minWidth: 690)
        compactWorkspace
      }
      .onAppear { synchronizeCompactPath() }
      .onChange(of: store.selectedTaskID) { _, _ in synchronizeCompactPath() }
      .onChange(of: compactPath) { _, path in
        store.selectTask(path.last)
      }
    }
  }

  private var wideWorkspace: some View {
    HSplitView {
      List(page.tasks, selection: taskSelection) { task in
        TaskCompactRow(task: task)
          .tag(task.id)
          .padding(.vertical, BridgeTheme.spacingTight)
      }
      .frame(minWidth: 250, idealWidth: 320)
      .accessibilityLabel("任务列表")

      detail
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var compactWorkspace: some View {
    NavigationStack(path: $compactPath) {
      List(page.tasks) { task in
        NavigationLink(value: task.id) {
          TaskCompactRow(task: task)
            .padding(.vertical, BridgeTheme.spacingTight)
        }
      }
      .accessibilityLabel("任务列表")
      .navigationTitle("任务")
      .navigationDestination(for: String.self) { taskID in
        if let task = page.details.first(where: { $0.id == taskID }) {
          TaskDetailView(task: task, store: store)
        } else {
          ContentUnavailableView(
            "没有任务详情",
            systemImage: "doc.text.magnifyingglass",
            description: Text("等待任务详情完成同步。")
          )
        }
      }
      .onAppear { synchronizeCompactPath() }
    }
  }

  private func synchronizeCompactPath() {
    guard let selectedTaskID = store.selectedTaskID,
      page.tasks.contains(where: { $0.id == selectedTaskID })
    else {
      if !compactPath.isEmpty { compactPath.removeAll() }
      return
    }
    if compactPath.last != selectedTaskID { compactPath = [selectedTaskID] }
  }

  @ViewBuilder
  private var detail: some View {
    if let selectedTaskID = store.selectedTaskID,
      let detail = page.details.first(where: { $0.id == selectedTaskID })
    {
      TaskDetailView(task: detail, store: store)
    } else {
      ContentUnavailableView(
        "没有任务详情",
        systemImage: "doc.text.magnifyingglass",
        description: Text("选择一个任务，或等待任务详情完成同步。")
      )
    }
  }

  private var taskSelection: Binding<String?> {
    Binding(
      get: { store.selectedTaskID },
      set: { store.selectTask($0) }
    )
  }
}

private struct TaskDetailView: View {
  let task: TaskDetailPresentation
  @ObservedObject var store: BridgePresentationStore
  @State private var presentsVerificationAuthorization = false
  @State private var presentsRecoverySuspension = false
  @State private var supervisorActionToResolve: SupervisorActionPresentation?

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      controlBar
      Divider()
      evidencePicker
      ScrollView {
        evidenceContent
          .frame(maxWidth: BridgeTheme.readableTextWidth, alignment: .leading)
          .padding(.bottom, BridgeTheme.spacingPage)
      }
    }
    .padding(.leading, BridgeTheme.spacingSection)
    .confirmationDialog(
      "为当前 Turn 授权本机验证？",
      isPresented: $presentsVerificationAuthorization,
      titleVisibility: .visible
    ) {
      Button("仅授权这一次") {
        Task { await store.perform(.authorizeTaskVerification(task.id)) }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("授权只绑定当前任务、Turn、项目目录和已登记命令，五分钟后失效；不会授权未来任务。")
    }
    .confirmationDialog(
      "将任务标记为暂停？",
      isPresented: $presentsRecoverySuspension,
      titleVisibility: .visible
    ) {
      Button("标记为暂停") {
        Task { await store.perform(.suspendAmbiguousTask(task.id)) }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会释放当前 Thread 与工作区锁，但不会恢复旧进程、启动新 Turn 或修改项目文件。")
    }
    .confirmationDialog(
      "确认 Supervisor 动作已经生效？",
      isPresented: supervisorActionResolutionPresented,
      titleVisibility: .visible
    ) {
      Button("标记为已应用") {
        guard let action = supervisorActionToResolve else { return }
        Task {
          await store.perform(
            .markSupervisorActionApplied(taskID: task.id, actionID: action.id)
          )
        }
        supervisorActionToResolve = nil
      }
      Button("取消", role: .cancel) {
        supervisorActionToResolve = nil
      }
    } message: {
      if let action = supervisorActionToResolve {
        Text("请先在 Codex 中核对“\(action.kind)”动作已生效。Bridge 不会重试该动作，也不会替你执行外部操作。")
      }
    }
    .task(id: "\(task.id):\(task.status.rawValue)") {
      _ = await store.perform(.loadTaskEvidence(task.id))
    }
  }

  private var controlBar: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
          Text(task.title)
            .font(.title3.weight(.semibold))
          StatusLabel(status: task.status)
        }
        Spacer()
        Button("在 Codex 中打开", systemImage: "arrow.up.forward.app") {
          Task { await store.perform(.openTaskInCodex(task.id)) }
        }
        .disabled(!task.canOpenInCodex)
        .help(
          task.canOpenInCodex
            ? "在 Codex 桌面端打开此任务绑定的线程"
            : "任务尚未绑定可打开的 Codex 线程"
        )
        Button("中断", systemImage: "stop.circle", role: .destructive) {
          Task { await store.perform(.interruptTask(task.id)) }
        }
        .disabled(!canInterrupt)
        .help(canInterrupt ? "请求 Codex 中断当前 turn" : "任务当前不可中断")
      }
      HStack(spacing: BridgeTheme.spacingSection) {
        Label(task.projectName, systemImage: "folder")
        Label(task.threadID, systemImage: "text.bubble")
          .font(.system(.caption, design: .monospaced))
        Label("\(task.model) · \(task.effort)", systemImage: "cpu")
        Label("Supervisor：\(task.supervisorStatus.label)", systemImage: "eye")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      if let recoveryMessage = task.recoveryMessage {
        HStack(alignment: .firstTextBaseline, spacing: BridgeTheme.spacingRegular) {
          Label(recoveryMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Spacer(minLength: BridgeTheme.spacingSection)
          Button("标记为暂停", systemImage: "pause.circle") {
            presentsRecoverySuspension = true
          }
          .disabled(!task.canSuspendAmbiguousRecovery)
          .help("释放任务占用的 Thread 与工作区锁，不启动新 Turn")
        }
        .font(.callout)
      }
    }
  }

  private var evidencePicker: some View {
    HStack {
      Text("证据")
        .font(.headline)
      Picker("任务证据视图", selection: $store.selectedTaskEvidenceTab) {
        ForEach(TaskEvidenceTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 160)
      Spacer()
      evidenceStatus
      Button("刷新证据", systemImage: "arrow.clockwise") {
        Task { _ = await store.perform(.loadTaskEvidence(task.id)) }
      }
      .buttonStyle(.borderless)
      .disabled(task.evidenceState == .loading)
      if let startedAt = task.startedAt {
        Text("开始于 \(startedAt.bridgeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var evidenceStatus: some View {
    switch task.evidenceState {
    case .notLoaded:
      Text("按需读取")
        .foregroundStyle(.secondary)
    case .loading:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("正在读取任务证据")
    case .available:
      Label("已核验", systemImage: "checkmark.shield")
        .foregroundStyle(.secondary)
    case .unavailable:
      Label("不可用", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var evidenceContent: some View {
    if case .unavailable(let message) = task.evidenceState {
      ContentUnavailableView(
        "证据不可用",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
    } else if task.evidenceState == .loading {
      ProgressView("正在核对持久证据…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      selectedEvidenceContent
    }
  }

  @ViewBuilder
  private var selectedEvidenceContent: some View {
    switch store.selectedTaskEvidenceTab {
    case .summary:
      TaskSummaryEvidence(task: task)
    case .timeline:
      TaskTimelineEvidence(events: task.timeline)
    case .commands:
      EvidenceCollection(title: "命令", items: task.commands, emptyMessage: "暂无命令证据")
    case .files:
      EvidenceCollection(title: "变更文件", items: task.changedFiles, emptyMessage: "暂无文件变更")
    case .diff:
      EvidenceSummary(title: "Diff", summary: task.diffSummary, emptyMessage: "暂无可显示的 Diff")
    case .supervision:
      VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
        EvidenceSummary(
          title: "Supervisor 模型",
          summary: task.supervisionSummary,
          emptyMessage: "尚未产生监督结论"
        )
        SupervisorActionResolutionView(
          actions: task.ambiguousSupervisorActions,
          resolve: { supervisorActionToResolve = $0 }
        )
      }
    case .verification:
      TaskVerificationEvidence(
        task: task,
        requestAuthorization: { presentsVerificationAuthorization = true }
      )
    case .logs:
      EvidenceSummary(
        title: "脱敏诊断日志",
        summary: task.diagnosticSummary,
        emptyMessage: "暂无诊断日志"
      )
    }
  }

  private var canInterrupt: Bool {
    task.canRequestInterrupt
  }

  private var supervisorActionResolutionPresented: Binding<Bool> {
    Binding(
      get: { supervisorActionToResolve != nil },
      set: { presented in
        if !presented { supervisorActionToResolve = nil }
      }
    )
  }
}

private struct TaskVerificationEvidence: View {
  let task: TaskDetailPresentation
  let requestAuthorization: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      HStack(alignment: .firstTextBaseline) {
        SectionHeading("验证", detail: "只运行项目已登记的命令")
        Spacer()
        Button("一次授权", systemImage: "checkmark.shield", action: requestAuthorization)
          .disabled(!task.canAuthorizeVerification || task.verificationCommands.isEmpty)
          .help(authorizationHelp)
      }
      if let summary = task.verificationSummary {
        Text(summary)
          .textSelection(.enabled)
      } else {
        Text("尚未产生测试或构建证据")
          .foregroundStyle(.secondary)
      }
      Divider()
      EvidenceCollection(
        title: "已登记命令",
        items: task.verificationCommands,
        emptyMessage: "项目没有登记验证命令"
      )
    }
  }

  private var authorizationHelp: String {
    if task.verificationCommands.isEmpty { return "项目没有可授权的验证命令" }
    if !task.canAuthorizeVerification { return "只可为当前运行中的 Turn 签发一次授权" }
    return "为当前任务和 Turn 的已登记验证命令签发五分钟一次性授权"
  }
}
