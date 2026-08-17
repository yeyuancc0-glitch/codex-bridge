import BridgeIPC
import BridgeMCP
import SwiftUI

struct BridgeServiceTasksView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "任务",
          subtitle: "ChatGPT 提交任务后，本机批准、Codex 审批和执行状态都在这里处理。"
        )

        if !model.approvals.isEmpty {
          approvalsSection
          Divider()
        }

        if model.tasks.isEmpty {
          ContentUnavailableView(
            "暂无任务",
            systemImage: "list.bullet.rectangle",
            description: Text("ChatGPT 通过 MCP 提交的任务会出现在这里。")
          )
          .frame(maxWidth: .infinity, minHeight: 280)
        } else {
          taskSection
        }
      }
      .padding(24)
      .frame(maxWidth: 1_000, alignment: .leading)
    }
    .navigationTitle("任务")
  }

  private var approvalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Codex 操作审批")
        .font(.headline)
      ForEach(model.approvals, id: \.approvalID) { approval in
        ApprovalRow(model: model, approval: approval)
        if approval.approvalID != model.approvals.last?.approvalID {
          Divider()
        }
      }
    }
  }

  private var taskSection: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(model.tasks, id: \.taskID) { task in
        TaskRow(model: model, task: task)
        if task.taskID != model.tasks.last?.taskID {
          Divider()
        }
      }
    }
  }
}

private struct ApprovalRow: View {
  @ObservedObject var model: BridgeServiceAppModel
  let approval: IPCApprovalSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(approval.title, systemImage: "exclamationmark.shield")
          .font(.headline)
        Spacer()
        Text(approval.kind)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Text(approval.summary)
      if let displayCommand = approval.displayCommand {
        Text(displayCommand)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.35))
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      if !approval.relativePaths.isEmpty {
        Text(approval.relativePaths.joined(separator: "\n"))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let reason = approval.reason {
        Text(reason)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button("拒绝", role: .destructive) {
          model.resolveApproval(approval, allow: false)
        }
        Button("仅本次允许") {
          model.resolveApproval(approval, allow: true)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 12)
  }
}

private struct TaskRow: View {
  @ObservedObject var model: BridgeServiceAppModel
  let task: MCPServiceTaskSnapshot
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        TaskStatusLabel(status: task.status)
        Spacer()
        Text(task.updatedAt)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Text(task.currentStep ?? task.resultSummary ?? task.taskID)
        .lineLimit(expanded ? nil : 2)
      Text(task.projectID)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if task.status == "awaiting_local_approval" {
        HStack {
          Button("拒绝任务", role: .destructive) {
            model.rejectTask(task.taskID)
          }
          Button("批准并启动") {
            model.approveTask(task.taskID)
          }
          .buttonStyle(.borderedProminent)
        }
      } else if isActive {
        Button("中断任务", role: .destructive) {
          model.stopTask(task.taskID)
        }
      }

      if expanded {
        taskDetails
      }

      Button(expanded ? "收起详情" : "查看详情") {
        expanded.toggle()
      }
      .buttonStyle(.link)
    }
    .padding(.vertical, 14)
  }

  private var isActive: Bool {
    ["starting", "running", "waiting_for_codex_approval"].contains(task.status)
  }

  private var taskDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
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
      LabeledContent("Supervisor", value: task.supervisorStatus)
      if let summary = task.supervisorSummary {
        Text(summary)
          .foregroundStyle(.secondary)
      }
      if !task.changedFiles.isEmpty {
        Text("变更文件")
          .font(.subheadline.weight(.semibold))
        ForEach(task.changedFiles, id: \.self) { path in
          Text(path)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
      if let failureCode = task.failureCode {
        LabeledContent("失败代码", value: failureCode)
      }
      if !task.recentEvents.isEmpty {
        Text("最近事件")
          .font(.subheadline.weight(.semibold))
        ForEach(task.recentEvents, id: \.sequence) { event in
          HStack(alignment: .firstTextBaseline) {
            Text("#\(event.sequence)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(event.summary)
          }
        }
      }
    }
    .padding(.leading, 12)
  }
}
