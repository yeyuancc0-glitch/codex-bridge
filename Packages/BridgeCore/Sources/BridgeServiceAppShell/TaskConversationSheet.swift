import BridgeMCP
import SwiftUI
import BridgeServiceAppCore

struct TaskConversationSheet: View {
  @ObservedObject var model: BridgeServiceAppModel
  @ObservedObject var conversation: TaskConversationModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      messages
      Divider()
      footer
    }
    .frame(minWidth: 520, minHeight: 420)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label("任务对话", systemImage: "bubble.left.and.bubble.right.fill")
        .font(.headline)
      Text(conversation.taskID)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button {
        conversation.autoScroll.toggle()
      } label: {
        Label(
          conversation.autoScroll ? "自动滚动" : "手动滚动",
          systemImage: conversation.autoScroll
            ? "arrow.down.to.line.compact"
            : "arrow.down.to.line"
        )
        .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(12)
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if conversation.isLoadingEarlier {
            HStack {
              Spacer()
              ProgressView()
                .controlSize(.small)
              Spacer()
            }
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
              streaming: isStreaming(entry),
              providerID: task?.providerIdentifier ?? "codex"
            )
          }

          if isWaitingForCodex {
            ThinkingBubbleView(
              statusText: activity.statusText,
              detailText: activity.detailText
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
          }
        }
        .padding(12)
      }
      .onChange(of: conversation.scrollAnchor) { _, anchor in
        guard let anchor else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(anchor, anchor: .bottom)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      if let errorMessage = conversation.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      } else if activity.isActive {
        HStack(spacing: 6) {
          ThinkingOrbView(size: 14)
          Text(activity.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if task != nil {
        Text(activity.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("\(conversation.entries.count) 条消息")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("关闭") {
        model.closeConversation()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(10)
  }

  private var isWaitingForCodex: Bool {
    activity.showsBubble
  }

  private func isStreaming(_ entry: TaskConversationModel.Entry) -> Bool {
    entry.role == "agent" && !entry.isFinal
  }

  private var task: MCPServiceTaskSnapshot? {
    model.tasks.first(where: { $0.taskID == conversation.taskID })
  }

  private var activity: CodexActivityPresentation {
    CodexActivityPresentation(task: task, activity: conversation.activity)
  }
}

struct MessageBubble: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool
  var providerID = "codex"

  var body: some View {
    switch entry.kind {
    case "reasoning":
      ReasoningBubbleView(entry: entry, streaming: streaming, providerID: providerID)
    case "tool_call":
      ToolCallBubbleView(entry: entry, providerID: providerID)
    default:
      TextBubbleView(entry: entry, streaming: streaming)
    }
  }
}

struct TextBubbleView: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool

  var body: some View {
    let isUser = entry.role == "user"
    HStack(alignment: .top, spacing: 0) {
      if isUser {
        Spacer(minLength: 40)
      }
      AgentMarkdownText(entry.content, isStreaming: streaming, fillsWidth: !isUser)
        .font(.system(size: 13))
        .textSelection(.enabled)
        .lineSpacing(2)
        .padding(isUser ? 10 : 0)
        .background {
          if isUser {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          }
        }
      if !isUser {
        Spacer(minLength: 24)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }
}

struct ReasoningBubbleView: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool
  let providerID: String
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
          Image(systemName: "brain.head.profile")
            .font(.caption2.weight(.semibold))
          Text(
            CodexTranscriptPresentation.reasoningTitle(
              providerID: providerID,
              streaming: streaming
            )
          )
          .font(.caption.weight(.semibold))
          if streaming {
            ThinkingOrbView(size: 10)
          }
          Spacer()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        AgentMarkdownText(entry.content, isStreaming: streaming)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineSpacing(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 18)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ToolCallBubbleView: View {
  let entry: TaskConversationModel.Entry
  let providerID: String
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
          statusIcon
            .font(.caption)
          Text(presentation.title)
            .font(.callout.weight(.medium))
          Text(statusLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded, let details, !details.isEmpty {
        Text(details)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 36)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch entry.toolStatus {
    case "completed":
      Image(systemName: presentation.systemImage)
        .foregroundStyle(.secondary)
    case "failed":
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    case "declined":
      Image(systemName: "minus.circle.fill")
        .foregroundStyle(.orange)
    case "cancelled":
      Image(systemName: "xmark.circle")
        .foregroundStyle(.secondary)
    default:
      ThinkingOrbView(size: 11)
    }
  }

  private var statusLabel: String {
    CodexTranscriptPresentation.statusLabel(entry.toolStatus)
  }

  private var presentation: CodexTranscriptToolPresentation {
    CodexTranscriptPresentation.tool(
      providerID: providerID,
      name: entry.toolName,
      status: entry.toolStatus
    )
  }

  private var details: String? {
    if let arguments = entry.toolArguments, !arguments.isEmpty { return arguments }
    return entry.content.isEmpty ? nil : entry.content
  }
}
