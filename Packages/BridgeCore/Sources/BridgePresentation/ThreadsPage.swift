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
        ThreadList(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct ThreadList: View {
  let page: ThreadPagePresentation
  @ObservedObject var store: BridgePresentationStore

  @ViewBuilder
  var body: some View {
    if page.threads.isEmpty {
      ContentUnavailableView(
        "没有可用线程",
        systemImage: "text.bubble",
        description: Text("确认 Codex 登录、项目路径和 Thread 来源后重试。")
      )
    } else {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
        if let projectFilterName = page.projectFilterName {
          Label("项目：\(projectFilterName)", systemImage: "line.3.horizontal.decrease.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
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
                Task { await store.perform(.openThreadInCodex(thread.id)) }
              }
              .disabled(!thread.canOpenInCodex)
              .help(thread.canOpenInCodex ? "在 Codex 中打开此线程" : "Codex 打开能力尚不可用")
              Menu("更多操作", systemImage: "ellipsis.circle") {
                Button("读取历史", systemImage: "clock.arrow.circlepath") {
                  Task { await store.perform(.readThreadHistory(thread.id)) }
                }
                .disabled(!thread.canReadHistory)
                Button("继续线程", systemImage: "arrow.forward.circle") {
                  Task { await store.perform(.continueThread(thread.id)) }
                }
                .disabled(!thread.canContinueNow)
                Button("创建新任务", systemImage: "plus.circle") {
                  Task { await store.perform(.createTaskFromThread(thread.id)) }
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
      }
    }
  }
}
