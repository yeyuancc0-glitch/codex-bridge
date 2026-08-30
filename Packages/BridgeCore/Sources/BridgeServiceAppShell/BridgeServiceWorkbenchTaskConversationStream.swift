import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceWorkbenchTaskConversationStream: View {
  @ObservedObject var conversation: TaskConversationModel
  let activity: CodexActivityPresentation
  let providerID: String

  @ViewBuilder
  var body: some View {
    if conversation.entries.isEmpty {
      if activity.showsBubble {
        WorkbenchConversationWaitingView(activity: activity)
      } else {
        WorkbenchConversationEmptyView(hasSelectedTask: true)
      }
    } else {
      LazyVStack(alignment: .leading, spacing: 10) {
        paginationControl

        ForEach(conversation.entries) { entry in
          MessageBubble(
            entry: entry,
            streaming: entry.role == "agent" && !entry.isFinal,
            providerID: providerID
          )
          .id(entry.key)
        }

        if activity.showsBubble {
          ThinkingBubbleView(
            statusText: activity.statusText,
            detailText: activity.detailText
          )
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
    }
  }

  @ViewBuilder
  private var paginationControl: some View {
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
  }
}

struct WorkbenchConversationWaitingView: View {
  let activity: CodexActivityPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ThinkingBubbleView(
        statusText: activity.statusText,
        detailText: activity.detailText
      )
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
  }
}

struct WorkbenchConversationEmptyView: View {
  let hasSelectedTask: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: hasSelectedTask ? "bubble.left.and.bubble.right" : "sparkles")
        .font(.system(size: 24))
        .foregroundStyle(.secondary)
      Text(hasSelectedTask ? "正在同步对话内容" : "等待 ChatGPT 指令")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(detailText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, minHeight: 240)
  }

  private var detailText: String {
    if hasSelectedTask {
      return "任务已经选中，完整对话内容正在从后台 Service 读取。"
    }
    return "在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与所选 Provider 的执行结果。"
  }
}
