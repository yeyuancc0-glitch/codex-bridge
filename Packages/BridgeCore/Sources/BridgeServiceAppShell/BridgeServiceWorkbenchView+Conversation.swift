import BridgeMCP
import SwiftUI

struct BridgeServiceWorkbenchInspectorLiveRegion: View {
  @ObservedObject var model: BridgeServiceAppModel
  let context: BridgeServiceWorkbenchInspectorContext

  @ViewBuilder
  var body: some View {
    if let conversation = model.conversation {
      BridgeServiceWorkbenchObservedLiveRegion(
        model: model,
        conversation: conversation,
        context: context
      )
      .id(conversation.id)
    } else {
      BridgeServiceWorkbenchInspectorBody(
        model: model,
        context: context,
        conversation: nil,
        activity: context.activity
      )
      .frame(minHeight: 0, maxHeight: .infinity)
      Divider()
      BridgeServiceWorkbenchInspectorFooter(model: model, activity: context.activity)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct BridgeServiceWorkbenchObservedLiveRegion: View {
  @ObservedObject var model: BridgeServiceAppModel
  @ObservedObject var conversation: TaskConversationModel
  let context: BridgeServiceWorkbenchInspectorContext

  var body: some View {
    let activity = CodexActivityPresentation(
      task: context.currentTask ?? context.currentActiveTask,
      activity: conversation.activity
    )
    BridgeServiceWorkbenchInspectorBody(
      model: model,
      context: context,
      conversation: conversation,
      activity: activity
    )
    .frame(minHeight: 0, maxHeight: .infinity)
    Divider()
    BridgeServiceWorkbenchInspectorFooter(model: model, activity: activity)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct BridgeServiceWorkbenchInspectorBody: View {
  @ObservedObject var model: BridgeServiceAppModel
  let context: BridgeServiceWorkbenchInspectorContext
  let conversation: TaskConversationModel?
  let activity: CodexActivityPresentation

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 12) {
          if let task = context.currentTask, task.isExternalAgentTask {
            WorkbenchExternalTaskCard(task: task)
          }

          if let message = model.conversation?.errorMessage {
            WorkbenchConversationErrorCard(message: message)
          }

          if let activeTask = context.currentActiveTask, let step = activeTask.currentStep {
            NativeCard {
              VStack(alignment: .leading, spacing: 4) {
                Text("当前正在执行")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.secondary)
                Text(step)
                  .font(.caption)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }

          BridgeServiceWorkbenchConversationStream(
            conversation: conversation,
            selectedThread: model.selectedThread,
            hasSelectedTask: model.selectedTaskID != nil,
            activity: activity,
            providerID: context.currentTask?.providerIdentifier ?? "codex"
          )
        }
        .padding(12)
      }
      .frame(minHeight: 0, maxHeight: .infinity)
      .clipped()
      .onChange(of: conversation?.scrollRevision) { _, _ in
        guard let anchor = conversation?.scrollAnchor else { return }
        proxy.scrollTo(anchor, anchor: .bottom)
      }
      .task(id: conversation?.id) {
        await Task.yield()
        guard let conversation else { return }
        conversation.refreshPresentation()
        guard let anchor = conversation.scrollAnchor else { return }
        proxy.scrollTo(anchor, anchor: .bottom)
      }
    }
    .frame(minHeight: 0, maxHeight: .infinity)
    .layoutPriority(1)
  }
}

struct BridgeServiceWorkbenchConversationStream: View {
  let conversation: TaskConversationModel?
  let selectedThread: MCPThreadReadPage?
  let hasSelectedTask: Bool
  let activity: CodexActivityPresentation
  let providerID: String

  var body: some View {
    switch WorkbenchConversationSource.resolve(
      hasSelectedTask: hasSelectedTask,
      historicalEntryCount: selectedThread?.entries.count ?? 0
    ) {
    case .task:
      if let conversation, !conversation.entries.isEmpty {
        taskConversation(conversation)
      } else if isWaitingForProvider {
        waitingView
      } else {
        emptyTaskConversation
      }
    case .historicalThread:
      historicalThreadConversation(selectedThread)
    case .empty:
      if isWaitingForProvider {
        waitingView
      } else {
        emptyTaskConversation
      }
    }
  }

  @ViewBuilder
  private func taskConversation(_ conversation: TaskConversationModel) -> some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      if conversation.isLoadingEarlier {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
      } else if conversation.canLoadEarlier {
        Button("加载更早的消息") {
          Task {
            await conversation.loadEarlier()
          }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
      }

      ForEach(conversation.entries) { entry in
        MessageBubble(
          entry: entry,
          streaming: entry.role == "agent" && !entry.isFinal,
          providerID: providerID
        )
        .id(entry.key)
      }

      if isWaitingForProvider {
        ThinkingBubbleView(
          statusText: activity.statusText,
          detailText: activity.detailText
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
      }
    }
  }

  @ViewBuilder
  private func historicalThreadConversation(
    _ page: MCPThreadReadPage?
  ) -> some View {
    let entries =
      page?.entries.enumerated().map { index, entry in
        TaskConversationModel.Entry(
          historicalThreadEntry: entry,
          threadID: page?.thread.threadID ?? "historical",
          index: index
        )
      } ?? []
    LazyVStack(alignment: .leading, spacing: 10) {
      ForEach(entries) { entry in
        MessageBubble(entry: entry, streaming: false, providerID: "codex")
          .id(entry.key)
      }
    }
  }

  private var waitingView: some View {
    VStack(alignment: .leading, spacing: 10) {
      ThinkingBubbleView(
        statusText: activity.statusText,
        detailText: activity.detailText
      )
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
  }

  private var emptyTaskConversation: some View {
    VStack(spacing: 12) {
      Image(systemName: hasSelectedTask ? "bubble.left.and.bubble.right" : "sparkles")
        .font(.system(size: 24))
        .foregroundStyle(.secondary)
      Text(hasSelectedTask ? "正在同步对话内容" : "等待 ChatGPT 指令")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(
        hasSelectedTask
          ? "任务已经选中，完整对话内容正在从后台 Service 读取。"
          : "在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与所选 Provider 的执行结果。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, minHeight: 240)
  }

  private var isWaitingForProvider: Bool {
    activity.showsBubble
  }
}

struct BridgeServiceWorkbenchInspectorFooter: View {
  @ObservedObject var model: BridgeServiceAppModel
  let activity: CodexActivityPresentation

  var body: some View {
    HStack {
      if activity.isActive {
        HStack(spacing: 6) {
          ThinkingOrbView(size: 14)
          Text(activity.statusText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(activity.statusText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        model.refresh()
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
          .font(.caption2)
      }
      .buttonStyle(.borderless)
      .disabled(model.isRefreshing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
