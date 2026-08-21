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

  public final class Coordinator: NSObject, WKDownloadDelegate, WKNavigationDelegate, WKUIDelegate {
    let parent: ChatGPTWebView
    private var downloadDestinations: [ObjectIdentifier: DownloadDestination] = [:]

    private struct DownloadDestination {
      let target: URL
      let temporary: URL
    }

    init(_ parent: ChatGPTWebView) {
      self.parent = parent
    }

    // Direct new-window navigations back into the same WKWebView. Download
    // requests still pass through the navigation delegate, which converts them
    // to WKDownload without handing them to an external browser.
    public func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      guard Self.allows(navigationAction) else { return nil }
      if navigationAction.shouldPerformDownload {
        webView.startDownload(using: navigationAction.request) { [weak self] download in
          download.delegate = self
        }
        return nil
      }
      webView.load(navigationAction.request)
      return nil
    }

    // Block external URL schemes (e.g. chatgpt:// or x-webkit-app-launch://) so
    // WKWebView never hands login navigation to LaunchServices. http(s) stays
    // in-process; blob/data URLs are accepted only when WebKit marks them as a
    // download.
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
      guard Self.allows(navigationAction) else {
        return (.cancel, preferences)
      }
      if navigationAction.shouldPerformDownload {
        return (.download, preferences)
      }
      return (.allow, preferences)
    }

    public func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
      Self.shouldDownload(navigationResponse) ? .download : .allow
    }

    public func webView(
      _ webView: WKWebView,
      navigationAction: WKNavigationAction,
      didBecome download: WKDownload
    ) {
      download.delegate = self
    }

    public func webView(
      _ webView: WKWebView,
      navigationResponse: WKNavigationResponse,
      didBecome download: WKDownload
    ) {
      download.delegate = self
    }

    public func download(
      _ download: WKDownload,
      decideDestinationUsing response: URLResponse,
      suggestedFilename: String
    ) async -> URL? {
      let panel = NSSavePanel()
      panel.title = "保存下载文件"
      panel.prompt = "下载"
      panel.nameFieldStringValue = Self.safeFilename(suggestedFilename)
      panel.canCreateDirectories = true
      guard await panel.begin() == .OK else { return nil }
      guard let target = panel.url,
        let temporary = Self.temporaryDestination(for: target)
      else {
        return nil
      }
      downloadDestinations[ObjectIdentifier(download)] = DownloadDestination(
        target: target,
        temporary: temporary
      )
      return temporary
    }

    public func downloadDidFinish(_ download: WKDownload) {
      guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
      else {
        return
      }
      do {
        try Self.replaceDownloadedFile(
          temporary: destination.temporary,
          target: destination.target
        )
      } catch {
        try? FileManager.default.removeItem(at: destination.temporary)
      }
    }

    public func download(
      _ download: WKDownload,
      didFailWithError error: Error,
      resumeData: Data?
    ) {
      guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
      else {
        return
      }
      try? FileManager.default.removeItem(at: destination.temporary)
    }

    public func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      let nsError = error as NSError
      if nsError.code == NSURLErrorCancelled { return }
    }

    static func safeFilename(_ suggestedFilename: String) -> String {
      let filename = (suggestedFilename as NSString).lastPathComponent
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return filename.isEmpty || filename == "." ? "下载文件" : filename
    }

    static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
      shouldDownload(
        canShowMIMEType: navigationResponse.canShowMIMEType,
        response: navigationResponse.response)
    }

    static func shouldDownload(canShowMIMEType: Bool, response: URLResponse) -> Bool {
      if !canShowMIMEType { return true }
      guard let response = response as? HTTPURLResponse else { return false }
      return response.value(forHTTPHeaderField: "Content-Disposition")?
        .lowercased()
        .contains("attachment") == true
    }

    private static func allows(_ navigationAction: WKNavigationAction) -> Bool {
      guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return false }
      if scheme == "http" || scheme == "https" { return true }
      return navigationAction.shouldPerformDownload && (scheme == "blob" || scheme == "data")
    }

    static func temporaryDestination(for target: URL) -> URL? {
      let directory = target.deletingLastPathComponent()
      guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
      let temporary = directory.appendingPathComponent(
        ".codexbridge-download-\(UUID().uuidString.lowercased())",
        isDirectory: false
      )
      return FileManager.default.fileExists(atPath: temporary.path) ? nil : temporary
    }

    static func replaceDownloadedFile(temporary: URL, target: URL) throws {
      guard FileManager.default.fileExists(atPath: temporary.path) else { return }
      if FileManager.default.fileExists(atPath: target.path) {
        _ = try FileManager.default.replaceItemAt(
          target,
          withItemAt: temporary,
          backupItemName: nil,
          options: []
        )
      } else {
        try FileManager.default.moveItem(at: temporary, to: target)
      }
    }
  }
}
