#if os(Windows)
  import Dispatch
  import Foundation
  import WinSDK

  /// Owns the Win32 window and message queue on one stable OS thread. Swift's
  /// MainActor can resume on another Windows thread, so it must not pump HWND
  /// messages directly.
  final class WindowsUIThread: @unchecked Sendable {
    static let shared = WindowsUIThread()

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var actions: [@Sendable () -> Void] = []
    private var running = false
    private var started = false
    private var creationSucceeded = false
    private var chat: WindowsChatWebView?

    private init() {}

    func start() -> Bool {
      lock.lock()
      guard !started else {
        let succeeded = creationSucceeded
        lock.unlock()
        return succeeded
      }
      started = true
      lock.unlock()
      let thread = Thread { [self] in run() }
      thread.name = "codex-bridge.win32-ui"
      thread.stackSize = 1 << 20
      thread.start()
      guard ready.wait(timeout: .now() + 30) == .success else { return false }
      return lock.withLock { creationSucceeded }
    }

    func enqueue(_ action: @escaping @Sendable () -> Void) {
      let window = lock.withLock { () -> HWND? in
        guard running else { return nil }
        actions.append(action)
        return WindowsMainWindow.currentWindow()
      }
      if let window { _ = PostMessageW(window, UINT(WM_NULL), 0, 0) }
    }

    func isRunning() -> Bool {
      lock.withLock { running }
    }

    func chatWebView() -> WindowsChatWebView? {
      lock.withLock { chat }
    }

    private func run() {
      let activeChat = WindowsChatWebView()
      guard let window = WindowsMainWindow.create() else {
        ready.signal()
        return
      }
      WindowsMainWindow.chat = activeChat
      activeChat.attach(to: window)
      activeChat.setVisible(false)
      lock.withLock {
        chat = activeChat
        running = true
        creationSucceeded = true
      }
      ready.signal()

      var message = MSG()
      while GetMessageW(&message, nil, 0, 0) {
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
        drainActions()
      }
      drainActions()
      activeChat.shutdown()
      WindowsApprovalWindow.shutdown()
      WindowsProjectManagementWindow.shutdown()
      WindowsAgentManagementWindow.shutdown()
      WindowsWorkspaceWindow.shutdown()
      WindowsAgentDefaultsWindow.shutdown()
      WindowsLogWindow.shutdown()
      WindowsSettingsWindow.shutdown()
      WindowsConnectionWindow.shutdown()
      lock.withLock {
        actions.removeAll(keepingCapacity: false)
        chat = nil
        running = false
      }
    }

    private func drainActions() {
      let pending = lock.withLock { () -> [@Sendable () -> Void] in
        let pending = actions
        actions.removeAll(keepingCapacity: true)
        return pending
      }
      for action in pending { action() }
    }
  }
#endif
