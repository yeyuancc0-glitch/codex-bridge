import SwiftUI

struct TasksPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "任务",
        subtitle: "按事实状态检查任务，进入详情读取控制与证据",
        refreshAction: { await store.perform(.refresh(.tasks)) }
      )
      LoadStateView(
        state: store.snapshot.tasks,
        retry: { await store.perform(.refresh(.tasks)) }
      ) { page in
        TaskWorkspace(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct TaskWorkspace: View {
  let page: TaskPagePresentation
  @ObservedObject var store: BridgePresentationStore

  @ViewBuilder
  var body: some View {
    if page.tasks.isEmpty {
      ContentUnavailableView(
        "暂无任务",
        systemImage: "checklist",
        description: Text("从 ChatGPT 提交任务后会显示在这里。")
      )
    } else {
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
      if let startedAt = task.startedAt {
        Text("开始于 \(startedAt.bridgeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var evidenceContent: some View {
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
      EvidenceSummary(
        title: "Luna Supervisor",
        summary: task.supervisionSummary,
        emptyMessage: "尚未产生监督结论"
      )
    case .verification:
      EvidenceSummary(
        title: "验证",
        summary: task.verificationSummary,
        emptyMessage: "尚未产生测试或构建证据"
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
}
