import SwiftUI

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
              streaming: isStreaming(entry)
            )
          }

          if isWaitingForCodex {
            ThinkingBubbleView(
              statusText: "Codex 正在思考…",
              detailText: nil
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
      } else if isStreamingAny {
        HStack(spacing: 6) {
          ThinkingOrbView(size: 14)
          Text("Codex 正在输出…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if isWaitingForCodex {
        HStack(spacing: 6) {
          ThinkingOrbView(size: 14)
          Text("Codex 正在思考…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
    if conversation.isStreaming, let last = conversation.entries.last,
      last.role == "agent" && !last.content.isEmpty
    {
      return false
    }
    return conversation.isStreaming || (conversation.entries.last?.role == "user")
  }

  private func isStreaming(_ entry: TaskConversationModel.Entry) -> Bool {
    conversation.isStreaming && entry.key == conversation.entries.last?.key
      && entry.role == "agent" && !entry.isFinal
  }

  private var isStreamingAny: Bool {
    conversation.isStreaming
  }
}

struct MessageBubble: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool

  var body: some View {
    switch entry.kind {
    case "reasoning":
      ReasoningBubbleView(entry: entry, streaming: streaming)
    case "tool_call":
      ToolCallBubbleView(entry: entry)
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
      VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
        HStack(spacing: 4) {
          if isUser {
            Text("我")
              .font(.caption2.weight(.bold))
              .foregroundStyle(Color.blue)
            Image(systemName: "person.crop.circle.fill")
              .font(.caption2)
              .foregroundStyle(Color.blue)
          } else {
            Image(systemName: "cpu.fill")
              .font(.caption2)
              .foregroundStyle(Color.purple)
            Text("Codex")
              .font(.caption2.weight(.bold))
              .foregroundStyle(Color.purple)
          }
        }
        .padding(.horizontal, 2)

        Text(displayContent)
          .font(.system(size: 13))
          .textSelection(.enabled)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(
                isUser
                  ? Color.blue.opacity(0.08)
                  : Color(nsColor: .textBackgroundColor).opacity(0.6)
              )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(
                isUser ? Color.blue.opacity(0.25) : Color(nsColor: .separatorColor).opacity(0.35),
                lineWidth: 0.8
              )
          )
      }
      if !isUser {
        Spacer(minLength: 40)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private var displayContent: String {
    streaming ? entry.content + "▍" : entry.content
  }
}

struct ReasoningBubbleView: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool
  @State private var isExpanded = true

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
          Text("Codex 的思考")
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
        Text(displayContent)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineSpacing(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
          )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var displayContent: String {
    streaming ? entry.content + "▍" : entry.content
  }
}

struct ToolCallBubbleView: View {
  let entry: TaskConversationModel.Entry

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          statusIcon
            .font(.caption)
          Text(entry.toolName ?? "工具调用")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Spacer()
          Text(statusLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if let arguments = entry.toolArguments, !arguments.isEmpty {
          Text(arguments)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
        }
        if !entry.content.isEmpty, let arguments = entry.toolArguments,
          entry.content != arguments
        {
          Text(entry.content)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(6)
        }
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
      )
      Spacer(minLength: 64)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch entry.toolStatus {
    case "completed":
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case "failed":
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    default:
      ThinkingOrbView(size: 11)
    }
  }

  private var statusLabel: String {
    switch entry.toolStatus {
    case "completed": "已完成"
    case "failed": "失败"
    default: "进行中"
    }
  }
}
