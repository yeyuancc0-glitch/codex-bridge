import SwiftUI

struct TaskSummaryEvidence: View {
  let task: TaskDetailPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      SectionHeading("任务目标")
      Text(task.goal)
        .textSelection(.enabled)
      SectionHeading("计划")
      BulletList(items: task.plan, emptyMessage: "Codex 尚未提供计划")
      SectionHeading("当前步骤")
      Text(task.currentStep ?? "没有活动步骤")
        .foregroundStyle(task.currentStep == nil ? .secondary : .primary)
      SectionHeading("最终摘要")
      Text(task.finalSummary ?? "任务尚未形成最终报告")
        .foregroundStyle(task.finalSummary == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }
  }
}

struct TaskTimelineEvidence: View {
  let events: [TaskEvidenceEventPresentation]

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("时间线", detail: "Codex、Git、Supervisor 与审批事实按时间排列")
      if events.isEmpty {
        Text("暂无时间线事件")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events) { event in
          StatusRow(
            title: "\(event.source) · \(event.kind)",
            detail: "\(event.detail) · \(event.occurredAt.bridgeFormatted)",
            status: event.status
          )
          Divider()
        }
      }
    }
  }
}

struct EvidenceCollection: View {
  let title: String
  let items: [String]
  let emptyMessage: String

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading(title)
      if items.isEmpty {
        Text(emptyMessage)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          EvidenceText(text: item)
        }
      }
    }
  }
}

struct EvidenceSummary: View {
  let title: String
  let summary: String?
  let emptyMessage: String

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading(title)
      if let summary {
        EvidenceText(text: summary)
      } else {
        Text(emptyMessage)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct SupervisorActionResolutionView: View {
  let actions: [SupervisorActionPresentation]
  let resolve: (SupervisorActionPresentation) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading(
        "待操作员确认的 Supervisor 动作",
        detail: "RPC 结果不确定时不会自动重试；只有核对 Codex 当前状态后才能标记为已应用。"
      )
      if actions.isEmpty {
        Text("没有待确认的动作")
          .foregroundStyle(.secondary)
      } else {
        ForEach(actions) { action in
          VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
            HStack(alignment: .firstTextBaseline) {
              Label(action.kind, systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
              Spacer()
              Button("确认已应用", systemImage: "checkmark.shield") {
                resolve(action)
              }
              .help("核对 Codex 当前状态后，将这个不确定动作标记为已应用")
            }
            Text(action.instruction)
              .textSelection(.enabled)
            Text("任务事件序号 (action.taskEventSequence) · (action.createdAt.bridgeFormatted)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, BridgeTheme.spacingTight)
          Divider()
        }
      }
    }
  }
}
