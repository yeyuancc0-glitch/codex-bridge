import BridgeMCP
import SwiftUI

struct WorkbenchProviderTaskPicker: View {
  @ObservedObject var model: BridgeServiceAppModel
  let tasks: [MCPServiceTaskSnapshot]

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "list.bullet.rectangle")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Menu {
        ForEach(tasks, id: \.taskID) { task in
          Button {
            model.openTask(task.taskID)
          } label: {
            Label(
              WorkbenchTaskTextPresentation.menuTitle(for: task),
              systemImage: task.providerSystemImage
            )
          }
        }
      } label: {
        Text(selectedTaskLabel)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 250, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .frame(maxWidth: 250, alignment: .leading)
      .help(selectedTaskLabel)
    }
  }

  private var selectedTaskLabel: String {
    guard let task = tasks.first(where: { $0.taskID == model.selectedTaskID }) else {
      return "选择 Agent 任务（\(tasks.count)）"
    }
    return WorkbenchTaskTextPresentation.menuTitle(for: task)
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

        Text("原生 \(WorkbenchAgentPermissionPresentation.title(task.permissionMode))")
          .font(.caption2)
          .foregroundStyle(.secondary)

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
