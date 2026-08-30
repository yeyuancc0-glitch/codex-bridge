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
      if let conversation {
        BridgeServiceWorkbenchTaskConversationStream(
          conversation: conversation,
          activity: activity,
          providerID: providerID
        )
      } else if isWaitingForProvider {
        WorkbenchConversationWaitingView(activity: activity)
      } else {
        WorkbenchConversationEmptyView(hasSelectedTask: true)
      }
    case .historicalThread:
      historicalThreadConversation(selectedThread)
    case .empty:
      if isWaitingForProvider {
        WorkbenchConversationWaitingView(activity: activity)
      } else {
        WorkbenchConversationEmptyView(hasSelectedTask: false)
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
