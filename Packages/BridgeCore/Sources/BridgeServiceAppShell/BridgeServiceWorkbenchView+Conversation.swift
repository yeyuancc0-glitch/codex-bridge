import SwiftUI

struct BridgeServiceWorkbenchInspectorBody: View {
  @ObservedObject var model: BridgeServiceAppModel
  let context: BridgeServiceWorkbenchInspectorContext

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
            model: model,
            activity: context.activity
          )
        }
        .padding(12)
      }
      .frame(minHeight: 0, maxHeight: .infinity)
      .clipped()
      .onChange(of: model.conversation?.scrollAnchor) { _, anchor in
        guard let anchor else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(anchor, anchor: .bottom)
        }
      }
    }
    .frame(minHeight: 0, maxHeight: .infinity)
    .layoutPriority(1)
  }
}

struct BridgeServiceWorkbenchConversationStream: View {
  @ObservedObject var model: BridgeServiceAppModel
  let activity: CodexActivityPresentation

  var body: some View {
    if let conversation = model.conversation, !conversation.entries.isEmpty {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(conversation.entries) { entry in
          MessageBubble(entry: entry, streaming: entry.role == "agent" && !entry.isFinal)
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
    } else if let selectedThread = model.selectedThread, !selectedThread.entries.isEmpty {
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
