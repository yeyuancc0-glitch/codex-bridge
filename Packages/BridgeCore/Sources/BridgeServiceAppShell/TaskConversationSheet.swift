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
      } else {
        Text(isStreamingAny ? "Codex 正在输出…" : "\(conversation.entries.count) 条消息")
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

  private func isStreaming(_ entry: TaskConversationModel.Entry) -> Bool {
    conversation.isStreaming && entry.key == conversation.entries.last?.key
      && entry.role == "agent" && !entry.isFinal
  }

  private var isStreamingAny: Bool {
    conversation.isStreaming
  }
}

private struct MessageBubble: View {
  let entry: TaskConversationModel.Entry
  let streaming: Bool

  var body: some View {
    let isUser = entry.role == "user"
    HStack {
      if isUser {
        Spacer(minLength: 64)
      }
      VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
        Text(isUser ? "我" : "Codex")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(displayContent)
          .font(.body)
          .textSelection(.enabled)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(
                isUser
                  ? Color.accentColor.opacity(0.14)
                  : Color(nsColor: .textBackgroundColor).opacity(0.6)
              )
          )
      }
      if !isUser {
        Spacer(minLength: 64)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private var displayContent: String {
    streaming ? entry.content + "▍" : entry.content
  }
}