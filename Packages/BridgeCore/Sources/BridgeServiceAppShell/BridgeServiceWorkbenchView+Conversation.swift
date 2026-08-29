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
    }
    .frame(minHeight: 0, maxHeight: .infinity)
    .layoutPriority(1)
  }
}

struct BridgeServiceWorkbenchConversationStream: View {
  let conversation: TaskConversationModel?
  let selectedThread: MCPThreadReadPage?
  let activity: CodexActivityPresentation
  let providerID: String

  var body: some View {
    if let conversation, !conversation.entries.isEmpty {
      LazyVStack(alignment: .leading, spacing: 10) {
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
    } else if let selectedThread, !selectedThread.entries.isEmpty {
      let groups = ThreadTurnGroup.group(entries: selectedThread.entries)
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(groups) { group in
          ThreadChatBubbleView(group: group)
        }

        if isWaitingForProvider {
          ThinkingBubbleView(
            statusText: activity.statusText,
            detailText: activity.detailText
          )
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
    } else if isWaitingForProvider {
      VStack(alignment: .leading, spacing: 10) {
        ThinkingBubbleView(
          statusText: activity.statusText,
          detailText: activity.detailText
        )
      }
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.system(size: 24))
          .foregroundStyle(.secondary)
        Text("等待 ChatGPT 指令")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与所选 Provider 的执行结果。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 16)
      }
      .frame(maxWidth: .infinity, minHeight: 240)
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
