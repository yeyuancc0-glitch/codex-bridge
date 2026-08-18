import BridgeIPC
import BridgeMCP
import SwiftUI

struct BridgeServiceTasksView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "任务与审批",
          subtitle: "ChatGPT 提交的任务生命周期、本机安全审批与实时执行日志。",
          icon: "list.bullet.rectangle.portrait"
        )

        if !model.approvals.isEmpty {
          approvalsSection
        }

        if model.tasks.isEmpty && model.approvals.isEmpty {
          ContentUnavailableView(
            "暂无活动任务",
            systemImage: "checklist",
            description: Text("ChatGPT 通过 MCP 提交的任务与需要处理的本机审批将显示在这里。")
          )
          .frame(maxWidth: .infinity, minHeight: 320)
        } else if !model.tasks.isEmpty {
          taskSection
        }
      }
      .padding(24)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("任务")
    .sheet(item: $model.conversation) { conversation in
      TaskConversationSheet(model: model, conversation: conversation)
    }
  }

  private var approvalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Codex 操作审批", systemImage: "exclamationmark.shield.fill")
          .font(.headline)
          .foregroundStyle(.orange)
        Spacer()
        StatusBadge("\(model.approvals.count) 项待决定", tone: .warning)
      }

      VStack(spacing: 12) {
        ForEach(model.approvals, id: \.approvalID) { approval in
          ApprovalCard(model: model, approval: approval)
        }
      }
    }
  }

  private var taskSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("执行任务列表")
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        Text("共 \(model.tasks.count) 个任务")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(model.tasks, id: \.taskID) { task in
          TaskCard(model: model, task: task)
        }
      }
    }
  }
}

private struct ApprovalCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  let approval: IPCApprovalSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(approval.title, systemImage: "shield.lefthalf.filled")
          .font(.headline)
        Spacer()
        StatusBadge(approval.kind, tone: .warning)
      }

      Text(approval.summary)
        .font(.body)

      if let displayCommand = approval.displayCommand {
        CodeSnippetBlock(text: displayCommand, label: "即将执行的终端命令")
      }

      if !approval.relativePaths.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("目标文件路径")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

          ForEach(approval.relativePaths, id: \.self) { path in
            HStack(spacing: 6) {
              Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
          }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      if let reason = approval.reason {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      HStack(spacing: 12) {
        Button("拒绝操作", role: .destructive) {
          model.resolveApproval(approval, allow: false)
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("仅本次允许") {
          model.resolveApproval(approval, allow: true)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
    )
  }
}

private struct TaskCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  let task: MCPServiceTaskSnapshot
  @State private var expanded = false
  @State private var confirmingDelete = false

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 8) {
          TaskStatusLabel(status: task.status)

          HStack(spacing: 4) {
            Image(systemName: "folder")
              .font(.caption2)
            Text(task.projectID)
              .font(.caption.monospaced())
          }
          .foregroundStyle(.secondary)

          Spacer()

          Text(task.updatedAt)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Text(task.currentStep ?? task.resultSummary ?? task.taskID)
          .font(.body.weight(.medium))
          .lineLimit(expanded ? nil : 2)

        HStack {
          if isActive {
            Button("中断任务", role: .destructive) {
              model.stopTask(task.taskID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }

          Button("查看对话") {
            model.openConversation(taskID: task.taskID)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)

          if canDelete {
            Button("删除任务", role: .destructive) {
              confirmingDelete = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .confirmationDialog(
              "删除任务记录？",
              isPresented: $confirmingDelete,
              titleVisibility: .visible
            ) {
              Button("删除任务记录", role: .destructive) {
                model.deleteTask(task.taskID)
              }
              Button("取消", role: .cancel) {}
            } message: {
              Text(
                "将删除该任务的记录、事件与对话消息。正在执行的任务不能删除。"
              )
            }
          }

          Spacer()

          Button {
            withAnimation(.easeInOut(duration: 0.2)) {
              expanded.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Text(expanded ? "收起详情" : "展开执行详情")
              Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .font(.caption.weight(.medium))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }

        if expanded {
          Divider()
          taskDetails
        }
      }
    }
  }

  private var isActive: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(task.status)
  }

  private var canDelete: Bool {
    ["completed", "failed", "interrupted", "unknown"].contains(task.status)
  }

  private var taskDetails: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        if let threadID = task.threadID {
          LabeledContent("Thread") {
            Text(threadID)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        if let turnID = task.turnID {
          LabeledContent("Turn") {
            Text(turnID)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }

      HStack(alignment: .firstTextBaseline) {
        Text("Supervisor 监督：")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        StatusBadge(task.supervisorStatus, tone: supervisorTone)
      }

      if let summary = task.supervisorSummary {
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      if !task.changedFiles.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("变更文件 (\(task.changedFiles.count))")
            .font(.subheadline.weight(.semibold))

          ForEach(task.changedFiles, id: \.self) { path in
            HStack(spacing: 6) {
              Image(systemName: "doc.badge.plus")
                .font(.caption)
                .foregroundStyle(.blue)
              Text(path)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
          }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      if let failureCode = task.failureCode {
        HStack {
          Image(systemName: "xmark.octagon.fill")
            .foregroundStyle(.red)
          Text("失败代码: \(failureCode)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        }
      }

      if !task.recentEvents.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("执行日志事件")
            .font(.subheadline.weight(.semibold))

          VStack(alignment: .leading, spacing: 8) {
            ForEach(task.recentEvents, id: \.sequence) { event in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(event.sequence)")
                  .font(.system(size: 11, weight: .bold, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .frame(width: 32, alignment: .leading)

                Text(event.summary)
                  .font(.caption)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }
    }
  }

  private var supervisorTone: StatusTone {
    switch task.supervisorStatus.lowercased() {
    case "active", "completed", "clean": .success
    case "warning", "attention": .warning
    case "failed", "error": .error
    default: .neutral
    }
  }
}
