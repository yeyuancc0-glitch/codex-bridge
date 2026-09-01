#if os(Windows)
  import Foundation
  import WinSDK

  final class WindowsWebViewThread: @unchecked Sendable {
    typealias StateUpdate = @Sendable (WindowsChatWebView.State, String?) -> Void

    private enum Message {
      static let synchronize = UINT(WM_APP + 1)
      static let goBack = UINT(WM_APP + 2)
      static let goForward = UINT(WM_APP + 3)
      static let reload = UINT(WM_APP + 4)
    }

    private let parentWindow: HWND
    private let updateState: StateUpdate
    private let lock = NSLock()
    private let finished = CreateEventW(nil, true, false, nil)
    private var threadID: DWORD = 0
    private var pendingBounds = RECT()
    private var pendingVisible = false
    private var stopping = false
    private var completed = false
    private var shutdownNotification: (window: HWND, message: UINT)?

    private var loaderModule: HMODULE?
    private var environment: UnsafeMutableRawPointer?
    private var controller: UnsafeMutableRawPointer?
    private var webView: UnsafeMutableRawPointer?

    init(parentWindow: HWND, updateState: @escaping StateUpdate) {
      self.parentWindow = parentWindow
      self.updateState = updateState
    }

    deinit {
      if let finished { _ = CloseHandle(finished) }
    }

    func start() {
      Thread.detachNewThread { [self] in run() }
    }

    func resize(to bounds: RECT) {
      lock.withLock { pendingBounds = bounds }
      post(Message.synchronize)
    }

    func setVisible(_ visible: Bool) {
      lock.withLock { pendingVisible = visible }
      post(Message.synchronize)
    }

    func goBack() { post(Message.goBack) }
    func goForward() { post(Message.goForward) }
    func reload() { post(Message.reload) }

    func beginShutdown(notifying window: HWND, message: UINT) -> Bool {
      let target = lock.withLock { () -> DWORD? in
        guard !completed else { return nil }
        stopping = true
        shutdownNotification = (window, message)
        return threadID
      }
      guard let target else { return false }
      if target != 0 { _ = PostThreadMessageW(target, UINT(WM_QUIT), 0, 0) }
      return true
    }

    func shutdown() {
      let target = lock.withLock { () -> DWORD in
        stopping = true
        return threadID
      }
      if target != 0 { _ = PostThreadMessageW(target, UINT(WM_QUIT), 0, 0) }
      if let finished { _ = WaitForSingleObject(finished, 5_000) }
    }

    private func run() {
      let comInitialization = CoInitializeEx(nil, DWORD(0x2))
      defer {
        releaseInterfaces()
        if let loaderModule { _ = FreeLibrary(loaderModule) }
        if comInitialization >= 0 { CoUninitialize() }
        complete()
      }
      guard comInitialization >= 0 else {
        updateState(
          .unsupported,
          "无法创建 WebView2 所需的 STA COM 线程（\(hresult(comInitialization))）。"
        )
        return
      }
      var message = MSG()
      _ = PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE))
      let shouldStop = lock.withLock { () -> Bool in
        threadID = GetCurrentThreadId()
        return stopping
      }
      guard !shouldStop else { return }
      createEnvironment()
      while GetMessageW(&message, nil, 0, 0) {
        handle(message.message)
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
      }
    }

    private func createEnvironment() {
      guard let loader = loadLoader() else {
        updateState(.unsupported, "未找到随应用安装的 WebView2Loader.dll。")
        return
      }
      guard let create = loadCreateFunction(loader) else {
        _ = FreeLibrary(loader)
        updateState(.unsupported, "WebView2Loader.dll 缺少环境创建入口。")
        return
      }
      loaderModule = loader
      guard let userDataFolder = userDataFolderPath() else {
        updateState(.failed, "无法确定 WebView2 用户数据目录。")
        return
      }
      ensureDirectoryExists(userDataFolder)
      let handler = webView2CompletionHandler { [weak self] errorCode, environment in
        self?.environmentCreated(errorCode: errorCode, environment: environment)
      }
      let result = userDataFolder.withCString(encodedAs: UTF16.self) { folder in
        create(nil, folder, nil, handler)
      }
      _ = webView2Release(handler)
      if result != webview2SOK {
        updateState(.failed, "创建 WebView2 环境失败（\(hresult(result))）。")
      }
    }

    private func environmentCreated(errorCode: HRESULT, environment: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let environment else {
        updateState(.failed, "WebView2 环境初始化失败（\(hresult(errorCode))）。")
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
      let result = createController(environment, parentWindow, handler)
      _ = webView2Release(handler)
      if result != webview2SOK {
        updateState(.failed, "创建 WebView2 Controller 失败（\(hresult(result))）。")
      }
    }

    private func controllerCreated(errorCode: HRESULT, controller: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let controller else {
        updateState(.failed, "WebView2 Controller 初始化失败（\(hresult(errorCode))）。")
        return
      }
      self.controller = controller
      webView2AddRef(controller)
      synchronizeController()
      var pointer: UnsafeMutableRawPointer?
      let getWebView: WebView2GetCoreWebView2Fn = webView2Method(
        controller,
        WebView2Slot.controllerGetCoreWebView2,
        as: WebView2GetCoreWebView2Fn.self
      )
      guard getWebView(controller, &pointer) == webview2SOK, let webView = pointer else {
        updateState(.failed, "无法取得 WebView2 浏览器实例。")
        return
      }
      self.webView = webView
      let navigate: WebView2NavigateFn = webView2Method(
        webView,
        WebView2Slot.webViewNavigate,
        as: WebView2NavigateFn.self
      )
      _ = WindowsChatWebView.chatURL.withCString(encodedAs: UTF16.self) {
        navigate(webView, $0)
      }
      updateState(.active, nil)
    }

    private func handle(_ message: UINT) {
      switch message {
      case Message.synchronize: synchronizeController()
      case Message.goBack: runAction(WebView2Slot.webViewGoBack)
      case Message.goForward: runAction(WebView2Slot.webViewGoForward)
      case Message.reload: runAction(WebView2Slot.webViewReload)
      default: break
      }
    }

    private func synchronizeController() {
      guard let controller else { return }
      let values = lock.withLock { (pendingBounds, pendingVisible) }
      let putBounds: WebView2PutBoundsFn = webView2Method(
        controller, WebView2Slot.controllerPutBounds, as: WebView2PutBoundsFn.self)
      let putVisible: WebView2PutBoolFn = webView2Method(
        controller, WebView2Slot.controllerPutIsVisible, as: WebView2PutBoolFn.self)
      _ = putBounds(controller, values.0)
      _ = putVisible(controller, values.1)
    }

    private func runAction(_ slot: Int) {
      guard let webView else { return }
      let action: WebView2ActionFn = webView2Method(webView, slot, as: WebView2ActionFn.self)
      _ = action(webView)
    }

    private func post(_ message: UINT) {
      let target = lock.withLock { threadID }
      if target != 0 { _ = PostThreadMessageW(target, message, 0, 0) }
    }

    private func complete() {
      let notification = lock.withLock { () -> (window: HWND, message: UINT)? in
        completed = true
        threadID = 0
        return shutdownNotification
      }
      if let finished { _ = SetEvent(finished) }
      if let notification {
        _ = PostMessageW(notification.window, notification.message, 0, 0)
      }
    }

    private func releaseInterfaces() {
      if let controller {
        let close: WebView2ActionFn = webView2Method(
          controller, WebView2Slot.controllerClose, as: WebView2ActionFn.self)
        _ = close(controller)
      }
      for object in [webView, controller, environment].compactMap({ $0 }) {
        _ = webView2Release(object)
      }
      webView = nil
      controller = nil
      environment = nil
    }

    private func loadLoader() -> HMODULE? {
      "WebView2Loader.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
    }

    private func loadCreateFunction(_ loader: HMODULE) -> WebView2CreateEnvironmentFn? {
      guard
        let address = "CreateCoreWebView2EnvironmentWithOptions".withCString({
          GetProcAddress(loader, $0)
        })
      else { return nil }
      return unsafeBitCast(address, to: WebView2CreateEnvironmentFn.self)
    }

    private func userDataFolderPath() -> String? {
      let required = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
        GetEnvironmentVariableW($0, nil, 0)
      }
      guard required > 0 else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(required))
      let written = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
        GetEnvironmentVariableW($0, &buffer, required)
      }
      guard written > 0 else { return nil }
      var path = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      if path.hasSuffix("\\") { path.removeLast() }
      return path + "\\CodexBridge\\WebView2"
    }

    private func ensureDirectoryExists(_ path: String) {
      let root = path.dropLast("\\WebView2".count)
      for directory in [String(root), path] {
        directory.withCString(encodedAs: UTF16.self) { _ = CreateDirectoryW($0, nil) }
      }
    }

    private func hresult(_ value: HRESULT) -> String {
      String(format: "0x%08X", UInt32(bitPattern: value))
    }
  }
#endif
