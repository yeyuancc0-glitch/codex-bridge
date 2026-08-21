import SwiftUI

struct BlacklistRow: View {
  @Binding var draft: BridgeBlacklistDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "shield.slash")
          .font(.caption)
          .foregroundStyle(.red)

        TextField("可执行文件名 (例如: rm, dropdb)", text: $draft.executable)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)

        TextField("禁用参数正则/前缀 (例如: -rf, --force)", text: $draft.pattern)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)

        Spacer(minLength: 4)

        Button(role: .destructive) {
          withAnimation(.easeInOut(duration: 0.2)) {
            onRemove()
          }
        } label: {
          Image(systemName: "trash")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("删除此黑名单规则")
      }
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.8)
    )
  }
}

struct ProjectCommandRow: View {
  @Binding var draft: BridgeWorkspaceCommandDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        HStack(spacing: 6) {
          Image(systemName: "terminal")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("命令标识 (例如: build, test-unit)", text: $draft.name)
            .font(.body.weight(.medium))
            .textFieldStyle(.roundedBorder)
        }

        Spacer(minLength: 8)

        Button(role: .destructive) {
          withAnimation(.easeInOut(duration: 0.2)) {
            onRemove()
          }
        } label: {
          Image(systemName: "trash")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("删除此允许命令")
      }

      VStack(alignment: .leading, spacing: 3) {
        Text("可执行文件路径或项目内脚本：")
          .font(.caption2)
          .foregroundStyle(.secondary)
        TextField("例如: /usr/bin/git, Scripts/build.sh", text: $draft.executable)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)
      }

      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("参数前缀白名单（每行一个）：")
            .font(.caption2)
            .foregroundStyle(.secondary)
          TextField("例如: status\ncommit", text: $draft.arguments, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        }

        VStack(alignment: .leading, spacing: 3) {
          Text("工作目录（相对项目根）：")
            .font(.caption2)
            .foregroundStyle(.secondary)
          TextField("留空表示项目根目录", text: $draft.workingDirectory)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
      }

      HStack(spacing: 16) {
        Toggle("需要网络连接", isOn: $draft.requiresNetwork)
          .toggleStyle(.switch)
          .controlSize(.small)

        Picker("安全风险级别", selection: $draft.risk) {
          Text("普通命令").tag("normal")
          Text("高风险（每次均需本机审批）").tag("elevated")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)

        Spacer()
      }
    }
    .padding(14)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
    )
  }
}
