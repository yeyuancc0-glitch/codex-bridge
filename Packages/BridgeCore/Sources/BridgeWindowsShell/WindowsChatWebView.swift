#if os(Windows)
  import Foundation
  import WinSDK

  /// Embedded WebView2 browser hosting the chat page. All methods run on the
  /// shell's message-loop thread (WebView2 completion handlers are invoked
  /// there too), so no locking is required. Creation is asynchronous: attach()
  /// returns immediately and `state` transitions as the COM handlers fire.
  final class WindowsChatWebView {
    enum State: Equatable {
      case unsupported  // WebView2Loader.dll or the runtime is missing
      case loading
      case active
      case failed
    }

    static let chatURL = "https://chatgpt.com"

    private(set) var state: State
    private(set) var errorDetail: String?
    private let comAvailable: Bool
    private var loaderModule: HMODULE?
    private var hostWindow: HWND?
    private var environment: UnsafeMutableRawPointer?
    private var controller: UnsafeMutableRawPointer?
    private var webView: UnsafeMutableRawPointer?

    init(comAvailable: Bool = true) {
      self.comAvailable = comAvailable
      state = comAvailable ? .loading : .unsupported
      errorDetail = comAvailable ? nil : "当前 UI 线程未能进入 WebView2 要求的 STA COM 模式。"
    }

    convenience init(comInitialization: HRESULT, threadMatches: Bool) {
      self.init(comAvailable: comInitialization >= 0 && threadMatches)
      if !threadMatches {
        errorDetail = "UI 执行器未运行在初始化 STA COM 的入口线程。"
      } else if comInitialization < 0 {
        errorDetail = "STA COM 初始化失败（\(Self.hresult(comInitialization))）。"
      }
    }

    deinit {
      releaseInterfaces()
    }

    func attach(to window: HWND?) {
      guard comAvailable, hostWindow == nil, let window else { return }
      guard let loader = Self.loadLoader() else {
        state = .unsupported
        errorDetail = "未找到随应用安装的 WebView2Loader.dll。"
        return
      }
      guard
        let create = Self.loadCreateFunction(loader)
      else {
        state = .unsupported
        errorDetail = "WebView2Loader.dll 缺少环境创建入口。"
        return
      }
      loaderModule = loader
      hostWindow = window
      state = .loading

      guard let userDataFolder = Self.userDataFolderPath() else {
        state = .failed
        errorDetail = "无法确定 WebView2 用户数据目录。"
        return
      }
      Self.ensureDirectoryExists(userDataFolder)

      let handler = webView2CompletionHandler { [weak self] errorCode, environment in
        self?.environmentCreated(errorCode: errorCode, environment: environment)
      }
      let result = userDataFolder.withCString(encodedAs: UTF16.self) { folder in
        create(nil, folder, nil, handler)
      }
      _ = webView2Release(handler)
      if result != webview2SOK {
        state = .failed
        errorDetail = "创建 WebView2 环境失败（\(Self.hresult(result))）。"
      }
    }

    /// Synchronizes the browser bounds with the host client-area rect.
    func resize(to bounds: RECT) {
      guard let controller else { return }
      let putBounds: WebView2PutBoundsFn = webView2Method(
        controller,
        WebView2Slot.controllerPutBounds,
        as: WebView2PutBoundsFn.self
      )
      _ = putBounds(controller, bounds)
    }

    func setVisible(_ visible: Bool) {
      guard let controller else { return }
      let putIsVisible: WebView2PutBoolFn = webView2Method(
        controller,
        WebView2Slot.controllerPutIsVisible,
        as: WebView2PutBoolFn.self
      )
      _ = putIsVisible(controller, visible)
    }

    func shutdown() {
      releaseInterfaces()
    }

    func goBack() {
      runAction(slot: WebView2Slot.webViewGoBack)
    }

    func goForward() {
      runAction(slot: WebView2Slot.webViewGoForward)
    }

    func reload() {
      runAction(slot: WebView2Slot.webViewReload)
    }

    // MARK: - Completion handlers

    private func environmentCreated(errorCode: HRESULT, environment: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let environment, let hostWindow else {
        state = .failed
        errorDetail = "WebView2 环境初始化失败（\(Self.hresult(errorCode))）。"
        return
      }
      self.environment = environment
      webView2AddRef(environment)
      let createController: WebView2CreateControllerFn = webView2Method(
        environment,
        WebView2Slot.environmentCreateController,
        as: WebView2CreateControllerFn.self
      )
      let handler = webView2CompletionHandler { [weak self] errorCode, controller in
        self?.controllerCreated(errorCode: errorCode, controller: controller)
      }
      let result = createController(environment, hostWindow, handler)
      _ = webView2Release(handler)
      if result != webview2SOK {
        state = .failed
        errorDetail = "创建 WebView2 Controller 失败（\(Self.hresult(result))）。"
      }
    }

    private func controllerCreated(errorCode: HRESULT, controller: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let controller else {
        state = .failed
        errorDetail = "WebView2 Controller 初始化失败（\(Self.hresult(errorCode))）。"
        return
      }
      self.controller = controller
      webView2AddRef(controller)
      resize(to: WindowsMainWindow.workbenchChatBounds())
      setVisible(WindowsMainWindow.currentPage() == .workbench)

      var webViewPointer: UnsafeMutableRawPointer?
      let getWebView: WebView2GetCoreWebView2Fn = webView2Method(
        controller,
        WebView2Slot.controllerGetCoreWebView2,
        as: WebView2GetCoreWebView2Fn.self
      )
      guard getWebView(controller, &webViewPointer) == webview2SOK,
        let webView = webViewPointer
      else {
        state = .failed
        errorDetail = "无法取得 WebView2 浏览器实例。"
        return
      }
      self.webView = webView
      webView2AddRef(webView)
      navigate(to: Self.chatURL)
      errorDetail = nil
      state = .active
    }

    private func navigate(to url: String) {
      guard let webView else { return }
      let navigate: WebView2NavigateFn = webView2Method(
        webView,
        WebView2Slot.webViewNavigate,
        as: WebView2NavigateFn.self
      )
      _ = url.withCString(encodedAs: UTF16.self) { navigate(webView, $0) }
    }

    private func runAction(slot: Int) {
      guard let webView else { return }
      let action: WebView2ActionFn = webView2Method(
        webView,
        slot,
        as: WebView2ActionFn.self
      )
      _ = action(webView)
    }

    private func releaseInterfaces() {
      // Release children before parents: webView, then controller, then environment.
      for object in [webView, controller, environment].compactMap({ $0 }) {
        _ = webView2Release(object)
      }
      webView = nil
      controller = nil
      environment = nil
    }

    // MARK: - Static plumbing

    private static func loadLoader() -> HMODULE? {
      "WebView2Loader.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
    }

    private static func loadCreateFunction(_ loader: HMODULE) -> WebView2CreateEnvironmentFn? {
      let address = "CreateCoreWebView2EnvironmentWithOptions".withCString {
        GetProcAddress(loader, $0)
      }
      guard let address else { return nil }
      return unsafeBitCast(address, to: WebView2CreateEnvironmentFn.self)
    }

    /// %LOCALAPPDATA%\CodexBridge\WebView2, created on demand.
    static func userDataFolderPath() -> String? {
      let localAppData: String?
      let required = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
        GetEnvironmentVariableW($0, nil, 0)
      }
      if required > 0 {
        var buffer = [WCHAR](repeating: 0, count: Int(required))
        let written = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
          GetEnvironmentVariableW($0, &buffer, required)
        }
        localAppData =
          written > 0
          ? String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
          : nil
      } else {
        localAppData = nil
      }
      guard var path = localAppData else { return nil }
      if path.hasSuffix("\\") { path.removeLast() }
      return path + "\\CodexBridge\\WebView2"
    }

    private static func ensureDirectoryExists(_ path: String) {
      // Create both levels; ERROR_ALREADY_EXISTS is ignored.
      let root = path.dropLast("\\WebView2".count)
      for directory in [String(root), path] {
        directory.withCString(encodedAs: UTF16.self) {
          _ = CreateDirectoryW($0, nil)
        }
      }
    }

    private static func hresult(_ value: HRESULT) -> String {
      String(format: "0x%08X", UInt32(bitPattern: value))
    }
  }
#endif
