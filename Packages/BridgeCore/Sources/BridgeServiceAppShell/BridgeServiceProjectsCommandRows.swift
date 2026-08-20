import SwiftUI

struct BlacklistRow: View {
  @Binding var draft: BridgeBlacklistDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("可执行文件（可选）", text: $draft.executable)
          .textFieldStyle(.roundedBorder)
        TextField("参数子串（可选）", text: $draft.pattern)
          .textFieldStyle(.roundedBorder)
        Spacer()
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.8)
    )
  }
}

struct ProjectCommandRow: View {
  @Binding var draft: BridgeWorkspaceCommandDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("命令名称", text: $draft.name)
          .textFieldStyle(.roundedBorder)
        Spacer()
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }

      HStack(spacing: 8) {
        TextField("可执行文件 / 脚本路径", text: $draft.executable)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 8) {
        TextField("参数前缀（每行一个，可选）", text: $draft.arguments, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)

        TextField("工作目录（相对项目根，可选）", text: $draft.workingDirectory)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 12) {
        Toggle("需要网络", isOn: $draft.requiresNetwork)
          .toggleStyle(.switch)
          .controlSize(.small)

        Picker("风险", selection: $draft.risk) {
          Text("普通").tag("normal")
          Text("高风险（每次需批准）").tag("elevated")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)

        Spacer()
      }
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
    )
  }
}
