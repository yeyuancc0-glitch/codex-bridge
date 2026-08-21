import AppKit
import BridgeIPC
import BridgeMCP
import SwiftUI
import WebKit

struct BridgeServiceWorkbenchView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var isInspectorVisible = true

  var body: some View {
    HSplitView {
      browserPane
        .frame(minWidth: 320, maxWidth: .infinity)

      if isInspectorVisible {
        dockedInspectorPane
          .frame(minWidth: 280, idealWidth: 400, maxWidth: .infinity)
      }
    }
    .navigationTitle("工作台")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isInspectorVisible.toggle()
          }
        } label: {
          Label(
            isInspectorVisible ? "隐藏右侧面板" : "显示右侧面板",
            systemImage: isInspectorVisible ? "sidebar.right" : "sidebar.right"
          )
        }
        .help(isInspectorVisible ? "收起右侧实时监控面板" : "展开右侧实时监控面板")
      }
    }
    .task {
      if model.threads.isEmpty, let pID = model.selectedProjectID ?? model.projects.first?.projectID
      {
        model.selectProject(pID)
      }
    }
  }

  // MARK: - Left Pane: Embedded Browser

  private var browserPane: some View {
    VStack(spacing: 0) {
      browserToolbar
      Divider()
      if model.isChatBrowserEnabled {
        ChatGPTWebView(
          initialURL: model.chatBrowserResumeURL,
          webViewReference: $model.chatWebView
        )
      } else {
        browserDisabledPlaceholder
      }
    }
  }

  private var browserDisabledPlaceholder: some View {
    VStack(spacing: 10) {
      Image(systemName: "globe.slash")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
      Text("内置浏览器已关闭")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("点击左上角开关重新开启，登录状态会保留。")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var browserToolbar: some View {
    HStack(spacing: 8) {
      Button {
        model.chatWebView?.goBack()
      } label: {
        Image(systemName: "chevron.left")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .disabled(model.chatWebView?.canGoBack != true)

      Button {
        model.chatWebView?.goForward()
      } label: {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .disabled(model.chatWebView?.canGoForward != true)

      Button {
        model.chatWebView?.reload()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.caption)
      }
      .buttonStyle(.borderless)

      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

        Text("https://chatgpt.com")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      Spacer()

      Toggle(
        "内置浏览器",
        isOn: $model.isChatBrowserEnabled
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .font(.caption)
      .help("开启或关闭内置 ChatGPT 浏览器")

      Button {
        if let url = URL(string: "https://chatgpt.com") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label("在外部浏览器打开", systemImage: "safari")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Right Pane: Docked Inspector

  private var dockedInspectorPane: some View {
    VStack(spacing: 0) {
      inspectorHeader
      Divider()
      inspectorBody
      Divider()
      inspectorFooter
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var inspectorHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "folder.fill")
          .font(.system(size: 14))
          .foregroundStyle(.blue)

        Menu {
          ForEach(model.projects, id: \.projectID) { project in
            Button {
              model.selectProject(project.projectID)
            } label: {
              if project.projectID == model.selectedProjectID {
                Label(project.name, systemImage: "checkmark")
              } else {
                Text(project.name)
              }
            }
          }
        } label: {
          Text(model.projectName(for: model.selectedProjectID ?? ""))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)

        Spacer()

        if let task = currentTask {
          StatusBadge(task.sourceDisplayName, tone: .neutral)
          TaskStatusLabel(status: task.status)
        } else if model.runningTaskCount > 0 {
          StatusBadge("运行中", tone: .running)
        } else {
          StatusBadge("就绪", tone: .success)
        }
      }

      Text("GPT 调用 Codex 时，默认在当前选择的项目中执行")
        .font(.caption2)
        .foregroundStyle(.secondary)

      // Thread selector & status
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.caption2)
          .foregroundStyle(.secondary)

        if model.threads.isEmpty {
          Text("暂无已保存会话")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Menu {
            ForEach(model.threads, id: \.threadID) { thread in
              let title = thread.title ?? thread.preview ?? thread.threadID
              let compactTitle = WorkbenchThreadTitlePresentation.compact(
                title,
                maximumCharacters: 48
              )
              Button {
                model.openThread(thread.threadID)
              } label: {
                if thread.threadID == model.selectedThreadID {
                  Label(compactTitle, systemImage: "checkmark")
                    .accessibilityLabel(title)
                } else {
                  Text(compactTitle)
                    .accessibilityLabel(title)
                }
              }
            }
          } label: {
            Text(
              WorkbenchThreadTitlePresentation.compact(
                currentSelectedThreadTitle,
                maximumCharacters: 28
              )
            )
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 220, alignment: .leading)
          }
          .menuStyle(.borderlessButton)
          .frame(maxWidth: 220, alignment: .leading)
          .help(currentSelectedThreadTitle)
          .accessibilityLabel("当前会话：\(currentSelectedThreadTitle)")
        }

        Spacer()

        if let activeTask = currentActiveTask {
          Button("中断", role: .destructive) {
            model.stopTask(activeTask.taskID)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
    }
    .padding(12)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var inspectorBody: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          // Urgent Approvals
          if !model.approvals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(model.approvals, id: \.approvalID) { approval in
                ApprovalCard(model: model, approval: approval)
              }
            }
          }

          // Direct Workspace Approvals
          if !model.directApprovals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(model.directApprovals, id: \.approvalID) { approval in
                DirectApprovalCard(model: model, approval: approval)
              }
            }
          }

          // Active Task Step if Running
          if let activeTask = currentActiveTask, let step = activeTask.currentStep {
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

          // Conversation Stream
          conversationStreamView
        }
        .padding(12)
      }
      .onChange(of: model.conversation?.scrollAnchor) { _, anchor in
        guard let anchor else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(anchor, anchor: .bottom)
        }
      }
    }
  }

  @ViewBuilder
  private var conversationStreamView: some View {
    if let conversation = model.conversation, !conversation.entries.isEmpty {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(conversation.entries) { entry in
          MessageBubble(entry: entry, streaming: entry.role == "agent" && !entry.isFinal)
            .id(entry.key)
        }

        if isWaitingForCodex {
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

        if isWaitingForCodex {
          ThinkingBubbleView(
            statusText: activity.statusText,
            detailText: activity.detailText
          )
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
    } else if isWaitingForCodex {
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
        Text("在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与 Codex 执行结果。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 16)
      }
      .frame(maxWidth: .infinity, minHeight: 240)
    }
  }

  private var isWaitingForCodex: Bool {
    activity.showsBubble
  }

  private var inspectorFooter: some View {
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

  // MARK: - Helpers

  private var currentActiveTask: MCPServiceTaskSnapshot? {
    if let taskID = model.conversation?.taskID,
      let task = model.tasks.first(where: { $0.taskID == taskID && $0.isRunning })
    {
      return task
    }
    if let selectedThreadID = model.selectedThreadID,
      let task = model.tasks.first(where: { $0.threadID == selectedThreadID && $0.isRunning })
    {
      return task
    }
    return model.tasks.first(where: {
      $0.projectID == model.selectedProjectID && $0.isRunning
    }) ?? model.tasks.first(where: \.isRunning)
  }

  private var currentTask: MCPServiceTaskSnapshot? {
    if let taskID = model.conversation?.taskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    {
      return task
    }
    if let selectedThreadID = model.selectedThreadID,
      let task = model.tasks.first(where: { $0.threadID == selectedThreadID })
    {
      return task
    }
    return currentActiveTask
  }

  private var activity: CodexActivityPresentation {
    CodexActivityPresentation(
      task: currentActiveTask ?? currentTask,
      activity: model.conversation?.activity ?? .idle
    )
  }

  private var currentSelectedThreadTitle: String {
    guard let threadID = model.selectedThreadID else { return "选择会话" }
    return model.threads.first(where: { $0.threadID == threadID })?.title
      ?? model.threads.first(where: { $0.threadID == threadID })?.preview
      ?? threadID.prefix(8) + "…"
  }
}

package enum WorkbenchThreadTitlePresentation {
  package static func compact(_ value: String, maximumCharacters: Int) -> String {
    precondition(maximumCharacters >= 2)
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return "未命名会话" }
    guard normalized.count > maximumCharacters else { return normalized }
    return String(normalized.prefix(maximumCharacters - 1)) + "…"
  }
}

private struct ApprovalCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  let approval: IPCApprovalSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(approval.title, systemImage: "shield.lefthalf.filled")
          .font(.caption.weight(.bold))
        Spacer()
        StatusBadge(approval.kind, tone: .warning)
      }

      Text(approval.summary)
        .font(.caption)

      if let displayCommand = approval.displayCommand {
        CodeSnippetBlock(
          text: displayCommand,
          label: approval.kind == "permissions" ? "请求的权限范围" : "即将执行的终端命令"
        )
      }

      if !approval.relativePaths.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          Text("目标文件路径")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)

          ForEach(approval.relativePaths, id: \.self) { path in
            Text(path)
              .font(.system(size: 10, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }

      Divider()

      HStack(spacing: 8) {
        Button("拒绝", role: .destructive) {
          model.resolveApproval(approval, allow: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()

        Button("仅本次允许") {
          model.resolveApproval(approval, allow: true)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
    )
  }
}

private struct DirectApprovalCard: View {
  let model: BridgeServiceAppModel
  let approval: IPCPendingDirectApproval

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "terminal.fill")
          .foregroundStyle(.orange)
        Text("Direct 操作等待批准")
          .font(.caption.weight(.bold))
        Spacer()
        Text(approval.kind)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Text(approval.summary)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Text("项目 \(approval.projectID)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Text(approval.createdAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack(spacing: 8) {
        Button("拒绝") {
          model.resolveDirectApproval(approval, allow: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()

        Button("仅本次允许") {
          model.resolveDirectApproval(approval, allow: true)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.purple.opacity(0.5), lineWidth: 1)
    )
  }
}
