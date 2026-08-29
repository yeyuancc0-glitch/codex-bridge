import AppKit
import SwiftUI
import BridgeServiceAppCore

struct BridgeServiceWorkbenchBrowserPane: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    VStack(spacing: 0) {
      browserToolbar
      Divider()
      if model.isChatBrowserEnabled {
        ChatGPTWebView(
          initialURL: model.chatBrowserResumeURL,
          reloadRequest: model.chatBrowserReloadRequest,
          webViewReference: $model.chatWebView
        )
      } else {
        browserDisabledPlaceholder
      }
    }
  }

  private var browserDisabledPlaceholder: some View {
    VStack(spacing: 10) {
      Image(systemName: "globe.slash")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
      Text("内置浏览器已关闭")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("点击左上角开关重新开启，登录状态会保留。")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var browserToolbar: some View {
    HStack(spacing: 8) {
      browserNavigationButton(
        systemName: "chevron.left",
        help: "后退",
        enabled: model.chatWebView?.canGoBack == true
      ) {
        model.chatWebView?.goBack()
      }

      browserNavigationButton(
        systemName: "chevron.right",
        help: "前进",
        enabled: model.chatWebView?.canGoForward == true
      ) {
        model.chatWebView?.goForward()
      }

      browserNavigationButton(
        systemName: "arrow.clockwise",
        help: "刷新当前网页"
      ) {
        model.reloadChatBrowser()
      }

      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

        Text("https://chatgpt.com")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      Spacer()

      Toggle(
        "内置浏览器",
        isOn: $model.isChatBrowserEnabled
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .font(.caption)
      .help("开启或关闭内置 ChatGPT 浏览器")

      Button {
        if let url = URL(string: "https://chatgpt.com") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label("在外部浏览器打开", systemImage: "safari")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func browserNavigationButton(
    systemName: String,
    help: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
  }
}
