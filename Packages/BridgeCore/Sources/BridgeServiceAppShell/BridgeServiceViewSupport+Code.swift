import AppKit
import SwiftUI

public struct CodeSnippetBlock: View {
  public let text: String
  public var label: String? = nil
  public var onCopy: (() -> Void)? = nil

  @State private var isCopied = false

  public init(text: String, label: String? = nil, onCopy: (() -> Void)? = nil) {
    self.text = text
    self.label = label
    self.onCopy = onCopy
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label {
        HStack {
          Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            copyText()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
              Text(isCopied ? "已复制" : "复制")
                .font(.caption2.weight(isCopied ? .semibold : .regular))
            }
            .foregroundStyle(isCopied ? Color.green : Color.accentColor)
          }
          .buttonStyle(.borderless)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(text)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(
            isCopied ? Color.green.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.35),
            lineWidth: 0.8
          )
      )
    }
  }

  private func copyText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
      isCopied = true
    }
    onCopy?()
    Task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.easeInOut(duration: 0.2)) {
        isCopied = false
      }
    }
  }
}
