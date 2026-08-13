import SwiftUI

struct ThreadsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "线程",
        subtitle: "按项目读取真实 Codex Thread，不按标题猜测绑定",
        refreshAction: { await store.perform(.refresh(.threads)) }
      )
      LoadStateView(
        state: store.snapshot.threads,
        retry: { await store.perform(.refresh(.threads)) }
      ) { page in
        ThreadWorkspace(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct ThreadWorkspace: View {
  let page: ThreadPagePresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      projectPicker
      HSplitView {
        threadList
          .frame(minWidth: 360, idealWidth: 460, maxWidth: 580)
        history
          .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var projectPicker: some View {
    HStack {
      Picker("项目", selection: selectedProject) {
        ForEach(page.projectOptions) { project in
          Text(project.name).tag(Optional(project.id))
        }
      }
      .frame(maxWidth: 320)
      if !page.isCatalogLoaded {
        Label("尚未读取；点按右上角刷新", systemImage: "arrow.clockwise")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  @ViewBuilder
  private var threadList: some View {
    if page.threads.isEmpty {
      ContentUnavailableView(
        page.isCatalogLoaded ? "没有可用线程" : "尚未读取线程",
        systemImage: "text.bubble",
        description: Text(
          page.isCatalogLoaded
            ? "当前项目没有可见的 Codex Thread。"
            : "选择项目后刷新；Bridge 只读取工作目录精确匹配的 Thread。"
        )
      )
    } else {
      VStack(spacing: BridgeTheme.spacingRegular) {
        List(page.threads) { thread in
          HStack(alignment: .top, spacing: BridgeTheme.spacingRegular) {
            Image(systemName: thread.status.systemImage)
              .foregroundStyle(thread.status.tint)
              .frame(width: 20)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
              Text(thread.preview)
                .font(.body.weight(.medium))
              Text(thread.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Text("\(thread.projectName) · \(thread.source) · \(thread.modelDisplayValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: BridgeTheme.spacingTight) {
              Text(thread.isOccupied ? "Bridge 任务占用" : thread.status.label)
                .font(.caption)
                .foregroundStyle(thread.isOccupied ? .orange : thread.status.tint)
              Text(thread.updatedAt.bridgeFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("在 Codex 中打开", systemImage: "arrow.up.forward.app") {
                Task { await performOpen(thread) }
              }
              .disabled(!thread.canOpenInCodex)
              .help(thread.canOpenInCodex ? "在 Codex 中打开此线程" : "Codex 打开能力尚不可用")
              Menu("更多操作", systemImage: "ellipsis.circle") {
                Button("读取历史", systemImage: "clock.arrow.circlepath") {
                  Task { await performReadHistory(thread) }
                }
                .disabled(!thread.canReadHistory)
                Button("继续线程", systemImage: "arrow.forward.circle") {
                  Task { await prepareTask(thread) }
                }
                .disabled(!thread.canContinueNow)
                Button("创建新任务", systemImage: "plus.circle") {
                  Task { await prepareTask(thread) }
                }
                .disabled(!thread.canCreateTask)
                Button("复制 Thread ID", systemImage: "doc.on.doc") {
                  Task { await store.perform(.copyThreadID(thread.id)) }
                }
                if thread.canArchive {
                  Divider()
                  Button("归档 Supervisor 线程", systemImage: "archivebox") {
                    Task { await store.perform(.archiveSupervisorThread(thread.id)) }
                  }
                }
              }
            }
          }
          .padding(.vertical, BridgeTheme.spacingTight)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "线程 \(thread.id)，\(thread.preview)，\(thread.status.accessibilitySummary)，\(thread.isOccupied ? "已被 Bridge 任务占用" : "未占用")"
          )
        }
        .accessibilityLabel("Codex 线程列表")
        if page.canLoadMoreThreads || page.isLoadingMoreThreads {
          Button(page.isLoadingMoreThreads ? "正在读取" : "载入更多线程") {
            Task { await store.perform(.loadMoreThreads) }
          }
          .disabled(page.isLoadingMoreThreads)
        }
      }
    }
  }

  @ViewBuilder
  private var history: some View {
    if let state = page.history {
      LoadStateView(
        state: state,
        retry: { await retryHistory() },
        content: { history in
          ThreadHistoryView(history: history, store: store)
        }
      )
    } else {
      ContentUnavailableView(
        "选择 Thread 历史",
        systemImage: "clock.arrow.circlepath",
        description: Text("历史按当前项目读取，绝对工作目录不会显示在界面中。")
      )
    }
  }

  private var selectedProject: Binding<String?> {
    Binding(
      get: { page.selectedProjectID },
      set: { projectID in
        guard let projectID, projectID != page.selectedProjectID else { return }
        Task { await store.perform(.selectThreadProject(projectID)) }
      }
    )
  }

  private func performOpen(_ thread: ThreadPresentation) async {
    if let projectID = thread.projectID {
      await store.perform(.openBoundThreadInCodex(projectID: projectID, threadID: thread.id))
    } else {
      await store.perform(.openThreadInCodex(thread.id))
    }
  }

  private func performReadHistory(_ thread: ThreadPresentation) async {
    if let projectID = thread.projectID {
      await store.perform(.readBoundThreadHistory(projectID: projectID, threadID: thread.id))
    } else {
      await store.perform(.readThreadHistory(thread.id))
    }
  }

  @MainActor
  private func prepareTask(_ thread: ThreadPresentation) async {
    guard let projectID = thread.projectID else {
      await store.perform(.createTaskFromThread(thread.id))
      return
    }
    let prepared = await store.perform(
      .prepareReadOnlyTask(projectID: projectID, threadID: thread.id)
    )
    if prepared { store.destination = .tasks }
  }

  private func retryHistory() async {
    await store.perform(.refresh(.threads))
  }
}

private struct ThreadHistoryView: View {
  let history: ThreadHistoryPresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(history.title)
          .font(.title3.weight(.semibold))
        Text(history.threadID)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Divider()
      if history.entries.isEmpty {
        ContentUnavailableView(
          "没有可显示消息",
          systemImage: "text.bubble",
          description: Text("此 Thread 没有用户或助手文本记录。")
        )
      } else {
        List(history.entries) { entry in
          VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
            HStack {
              Label(roleTitle(entry.role), systemImage: roleImage(entry.role))
                .font(.caption.weight(.semibold))
              Spacer()
              Text(entry.turnID)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Text(entry.text)
              .textSelection(.enabled)
            if let status = entry.status {
              Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, BridgeTheme.spacingTight)
        }
        .accessibilityLabel("Thread 历史消息")
      }
      if history.isTruncated {
        Label("历史超过本机展示上限，已停止继续载入", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if history.canLoadMore || history.isLoadingMore {
        Button(history.isLoadingMore ? "正在读取" : "载入更多历史") {
          Task { await store.perform(.loadMoreThreadHistory) }
        }
        .disabled(history.isLoadingMore)
      }
    }
    .padding(.leading, BridgeTheme.spacingSection)
  }

  private func roleTitle(_ role: String) -> String {
    role == "assistant" ? "Codex" : "用户"
  }

  private func roleImage(_ role: String) -> String {
    role == "assistant" ? "cpu" : "person"
  }
}
