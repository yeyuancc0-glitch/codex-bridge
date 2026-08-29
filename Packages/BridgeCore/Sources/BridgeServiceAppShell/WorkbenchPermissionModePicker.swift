import SwiftUI

struct WorkbenchPermissionModePicker: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Label("GPT/Qwen 新任务", systemImage: "lock.square")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        Picker("新任务模式", selection: modeBinding) {
          Text("Read Only").tag("read-only")
          Text("Write").tag("workspace-write")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 160)
        .help("GPT/Qwen 未显式覆盖时，新 Agent 任务默认使用此读写模式。")
      }

      if projectWriteDenied {
        Label("当前项目禁止写入，新任务将按 Read Only 执行", systemImage: "lock.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  private var modeBinding: Binding<String> {
    Binding(
      get: { model.workbenchPermissionMode },
      set: { model.setWorkbenchPermissionMode($0) }
    )
  }

  private var projectWriteDenied: Bool {
    guard let projectID = model.selectedProjectID else { return false }
    return model.projects.first(where: { $0.projectID == projectID })?.capabilities.write
      == "denied"
  }
}
