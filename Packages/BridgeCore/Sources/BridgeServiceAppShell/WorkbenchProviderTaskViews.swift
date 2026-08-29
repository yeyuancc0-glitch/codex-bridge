import BridgeMCP
import SwiftUI

struct WorkbenchAgentTaskPicker: View {
  @ObservedObject var model: BridgeServiceAppModel
  let tasks: [MCPServiceTaskSnapshot]
  let threads: [MCPThreadSummary]

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "list.bullet.rectangle")
        .font(.caption2)
        .foregroundStyle(.secondary)

      if itemCount == 0 {
        Text("暂无 Agent 任务")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Menu {
          if !tasks.isEmpty {
            Section("Agent 任务") {
              ForEach(tasks, id: \.taskID) { task in
                taskButton(task)
              }
            }
          }

          if !orphanThreads.isEmpty {
            Section("Codex 历史会话") {
              ForEach(orphanThreads, id: \.threadID) { thread in
                Button {
                  model.openThread(thread.threadID)
                } label: {
                  Label(
                    threadTitle(thread),
                    systemImage: thread.threadID == model.selectedThreadID
                      ? "checkmark" : AgentProviderPresentation.systemImage("codex")
                  )
                }
              }
            }
          }
        } label: {
          Text(selectedItemLabel)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 250, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 250, alignment: .leading)
        .help(selectedItemLabel)
        .accessibilityLabel("当前 Agent 任务：\(selectedItemLabel)")
      }
    }
  }

  @ViewBuilder
  private func taskButton(_ task: MCPServiceTaskSnapshot) -> some View {
    Button {
      model.openTask(task.taskID)
    } label: {
      Label(
        WorkbenchTaskTextPresentation.menuTitle(for: task),
        systemImage: task.taskID == model.selectedTaskID ? "checkmark" : task.providerSystemImage
      )
    }
  }

  private var selectedItemLabel: String {
    if let task = tasks.first(where: {
      $0.taskID == model.selectedTaskID && $0.isExternalAgentTask
    }) {
      return WorkbenchTaskTextPresentation.menuTitle(for: task)
    }
    if let thread = threads.first(where: { $0.threadID == model.selectedThreadID }) {
      return "Codex · \(threadTitle(thread))"
    }
    if let task = tasks.first(where: { $0.taskID == model.selectedTaskID }) {
      return WorkbenchTaskTextPresentation.menuTitle(for: task)
    }
    return "选择 Agent 任务（\(itemCount)）"
  }

  private var itemCount: Int {
    WorkbenchAgentTaskPickerContent.itemCount(tasks: tasks, threads: threads)
  }

  private var orphanThreads: [MCPThreadSummary] {
    WorkbenchAgentTaskPickerContent.orphanThreads(tasks: tasks, threads: threads)
  }

  private func threadTitle(_ thread: MCPThreadSummary) -> String {
    WorkbenchThreadTitlePresentation.compact(
      thread.title ?? thread.preview ?? thread.threadID,
      maximumCharacters: 48
    )
  }
}

package enum WorkbenchAgentTaskPickerContent {
  package static func orphanThreads(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> [MCPThreadSummary] {
    let taskThreadIDs = Set(
      tasks.compactMap { task in
        task.isCodexTask ? task.threadID : nil
      })
    return threads.filter { !taskThreadIDs.contains($0.threadID) }
  }

  package static func itemCount(
    tasks: [MCPServiceTaskSnapshot],
    threads: [MCPThreadSummary]
  ) -> Int {
    tasks.count + orphanThreads(tasks: tasks, threads: threads).count
  }
}

struct WorkbenchExternalTaskCard: View {
  let task: MCPServiceTaskSnapshot

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label(task.providerDisplayName, systemImage: task.providerSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
          Spacer()
          TaskStatusLabel(status: task.status, providerID: task.providerID)
        }

        if let title = WorkbenchTaskTextPresentation.cardTitle(for: task) {
          Text(title)
            .font(.caption)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if task.providerIdentifier == "deepseek-harness" {
          Label(
            task.status == "completed"
              ? "Harness 仅报告会话已结束，任务完成度未被 Bridge 验证"
              : "实验性 Provider · 仅新会话",
            systemImage: task.status == "completed"
              ? "exclamationmark.triangle.fill" : "lock.shield.fill"
          )
          .font(.caption2)
          .foregroundStyle(.orange)
        } else {
          Text("原生 \(WorkbenchAgentPermissionPresentation.title(task.permissionMode))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if let failureDescription = task.failureDescription {
          Label {
            Text(failureDescription)
              .lineLimit(3)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .font(.caption2)
          .foregroundStyle(.red)
        }
      }
    }
  }
}

struct WorkbenchConversationErrorCard: View {
  let message: String

  var body: some View {
    NativeCard {
      Label {
        Text(message)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.caption)
      .foregroundStyle(.red)
    }
  }
}

package enum WorkbenchTaskTextPresentation {
  package static func menuTitle(for task: MCPServiceTaskSnapshot) -> String {
    let title = compact(task.workbenchTitle, maximumCharacters: 160) ?? "未命名任务"
    return "\(task.providerDisplayName) · \(title)"
  }

  package static func cardTitle(for task: MCPServiceTaskSnapshot) -> String? {
    compact(task.currentStep ?? task.resultSummary, maximumCharacters: 240)
  }

  private static func compact(_ value: String?, maximumCharacters: Int) -> String? {
    guard let value else { return nil }
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    guard normalized.count > maximumCharacters else { return normalized }
    return String(normalized.prefix(maximumCharacters - 1)) + "…"
  }
}
