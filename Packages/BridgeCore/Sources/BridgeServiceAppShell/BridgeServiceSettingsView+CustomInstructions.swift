import SwiftUI
import BridgeServiceAppCore

struct CustomInstructionsEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var draft = ""
  @State private var savedValue = ""

  private let maximumBytes = 32_768

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("全局自定义指令 (Custom Instructions)", systemImage: "text.badge.checkmark")
            .font(.headline)

          Spacer()

          if isWithinLimit && !draft.isEmpty {
            StatusBadge("\(draft.utf8.count) 字节", tone: .neutral)
          }
        }

        if model.customInstructions == nil {
          ProgressView("正在从 Service 读取自定义指令…")
        } else {
          TextEditor(text: $draft)
            .font(.system(size: 13, design: .monospaced))
            .frame(minHeight: 120, maxHeight: 180)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
            )
            .accessibilityLabel("全局自定义指令")

          HStack(alignment: .center) {
            Text(
              "ChatGPT 网页版与 Qwen 会在调用 Codex Bridge 插件前收到该指令（不传给 Codex/Agent 内核）。保存后 Qwen 重新连接即可生效；ChatGPT 还需在插件详情中刷新。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 16)

            Button("保存指令") {
              model.saveCustomInstructions(draft)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
              draft == savedValue || !isWithinLimit || model.isSavingCustomInstructions
            )
          }
        }
      }
    }
    .onAppear { synchronizeDraft(model.customInstructions) }
    .onChange(of: model.customInstructions) { _, value in synchronizeDraft(value) }
  }

  private var isWithinLimit: Bool {
    draft.utf8.count <= maximumBytes
  }

  private func synchronizeDraft(_ value: String?) {
    guard let value, value == draft || draft == savedValue else { return }
    draft = value
    savedValue = value
  }
}
