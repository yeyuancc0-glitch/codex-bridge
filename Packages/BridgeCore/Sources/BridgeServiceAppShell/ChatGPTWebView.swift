import AppKit
import SwiftUI
import WebKit

public struct ChatGPTWebView: NSViewRepresentable {
  public let initialURL: URL
  @Binding public var webViewReference: WKWebView?

  public init(
    initialURL: URL = URL(string: "https://chatgpt.com")!,
    webViewReference: Binding<WKWebView?> = .constant(nil)
  ) {
    self.initialURL = initialURL
    self._webViewReference = webViewReference
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  public func makeNSView(context: Context) -> WKWebView {
    // Reuse an existing instance (kept alive by the app model) so that leaving
    // and re-entering this view does not reload the page or lose its state.
    if let existing = webViewReference {
      return existing
    }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore.default()
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true

    let request = URLRequest(
      url: initialURL,
      cachePolicy: .useProtocolCachePolicy,
      timeoutInterval: 30
    )
    webView.load(request)

    DispatchQueue.main.async {
      self.webViewReference = webView
    }

    return webView
  }

  public func updateNSView(_ nsView: WKWebView, context: Context) {}

  public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let parent: ChatGPTWebView

    init(_ parent: ChatGPTWebView) {
      self.parent = parent
    }

    // Direct all new window requests back into the same WKWebView
    public func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url,
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      {
        webView.load(navigationAction.request)
      }
      return nil
    }

    // Block every non-http(s) navigation so WKWebView never hands external URL
    // schemes (e.g. chatgpt:// or x-webkit-app-launch://) to LaunchServices,
    // which would open the user's installed ChatGPT Safari Web App instead of
    // keeping the login flow inside this webview. http(s) navigations are always
    // allowed: WKWebView keeps them in-process and never routes them elsewhere.
    //
    // NOTE: implemented as the async variant because this SDK's WKNavigationDelegate
    // imports the requirement via WK_SWIFT_ASYNC; the decisionHandler-style method
    // is not exposed to ObjC (WebKit then treats it as unimplemented and allows
    // every navigation, including external-scheme handoff to Safari Web Apps).
    public func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
      guard let url = navigationAction.request.url,
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else {
        return (.cancel, preferences)
      }
      return (.allow, preferences)
    }

    public func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      let nsError = error as NSError
      if nsError.code == NSURLErrorCancelled { return }
    }
  }
}
