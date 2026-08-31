#if os(Windows)
  import Foundation
  import WinSDK

  /// Fixed layout metrics shared with the WebView2 bounds math.
  enum WindowLayout {
    static let sidebarWidth = 340
    static let statusInset = 8
    static let statusHeight = 76
    static let chatTopInset = statusHeight + statusInset + 4
    static let windowWidth = 1080
    static let windowHeight = 720
  }

  /// Owns the top-level window, menu, and tray icon. The task inspector owns
  /// child controls. All state is confined to the message-loop thread;
  /// `nonisolated(unsafe)` marks statics touched by the plain-C procedure.
  enum WindowsMainWindow {
    private static let windowClassName = WindowsApplicationIdentity.mainWindowClassName
    private static let windowTitle = "Codex Bridge"

    // CW_USEDEFAULT ((int)0x80000000); cast macros are not imported by WinSDK.
    private static let defaultPosition = Int32(bitPattern: 0x8000_0000)
    // MAKEINTRESOURCE(32512): IDI_APPLICATION / IDC_ARROW.
    private static let standardResourceID = 32_512

    private static let menuExitID: UINT_PTR = 1001
    private static let menuRefreshID: UINT_PTR = 1002
    private static let menuStartServiceID: UINT_PTR = 1003
    private static let menuApprovalsID: UINT_PTR = 1004
    private static let menuProjectsID: UINT_PTR = 1005
    private static let menuAgentsID: UINT_PTR = 1006
    private static let menuWorkspaceID: UINT_PTR = 1007
    private static let menuAgentDefaultsID: UINT_PTR = 1008
    private static let menuLogsID: UINT_PTR = 1009
    private static let menuSettingsID: UINT_PTR = 1010
    private static let timerID: UINT_PTR = 1
    private static let timerIntervalMs: UINT = 250

    // shellapi.h constants, declared locally to avoid macro-import variance.
    private static let trayNIMAdd: DWORD = 0
    private static let trayNIMDelete: DWORD = 2
    private static let trayNIFMessage: DWORD = 0x01
    private static let trayNIFIcon: DWORD = 0x02
    private static let trayNIFTip: DWORD = 0x04
    // offsetof(NOTIFYICONDATAW, szTip) on x64/ARM64 (fixed Win32 ABI).
    private static let trayTipOffset = 40
    private static let trayCallbackMessage: UINT = 0x8000 + 2

    nonisolated(unsafe) private static var pendingCommands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var trayData: NOTIFYICONDATAW?
    nonisolated(unsafe) static var chat: WindowsChatWebView?
    nonisolated(unsafe) static var window: HWND?

    static func create() -> HWND? {
      // Never NULL for a running process.
      let instance = GetModuleHandleW(nil)!
      registerWindowClass(instance)
      let created: HWND? = windowTitle.withCString(encodedAs: UTF16.self) { title -> HWND? in
        windowClassName.withCString(encodedAs: UTF16.self) { className in
          CreateWindowExW(
            0, className, title, DWORD(WS_OVERLAPPEDWINDOW),
            defaultPosition, defaultPosition,
            Int32(WindowLayout.windowWidth), Int32(WindowLayout.windowHeight),
            nil, nil, instance, nil
          )
        }
      }
      guard let window = created else { return nil }
      self.window = window
      WindowsTaskInspector.create(in: window, instance: instance)
      installMenu(window)
      installTrayIcon(window)
      _ = SetTimer(window, timerID, timerIntervalMs, nil)
      _ = ShowWindow(window, SW_SHOW)
      WindowsTaskInspector.layout(window, chat: chat)
      return window
    }

    static func enqueue(_ command: MainWindowCommand) {
      pendingCommands.append(command)
    }

    static func currentWindow() -> HWND? {
      window
    }

    static func takePendingCommands() -> [MainWindowCommand] {
      let commands = pendingCommands
      pendingCommands.removeAll()
      return commands
    }

    static func setStatusText(_ text: String) {
      WindowsTaskInspector.setStatusText(text)
    }

    static func setTaskRows(_ rows: [String], selectedIndex: Int?) {
      WindowsTaskInspector.setTaskRows(rows, selectedIndex: selectedIndex)
    }

    /// nil hides the placeholder (chat page active).
    static func setChatPlaceholder(_ text: String?) {
      WindowsTaskInspector.setChatPlaceholder(text)
    }

    // MARK: - Window procedure

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        if let command = WindowsTaskInspector.command(for: wParam) {
          pendingCommands.append(command)
          return 0
        }
        switch wParam & 0xFFFF {
        case menuExitID:
          _ = DestroyWindow(window)
        case menuRefreshID:
          pendingCommands.append(.refreshTasks)
        case menuStartServiceID:
          pendingCommands.append(.startService)
        case menuApprovalsID:
          pendingCommands.append(.showApprovals)
        case menuProjectsID:
          pendingCommands.append(.showProjects)
        case menuAgentsID:
          pendingCommands.append(.showAgents)
        case menuWorkspaceID:
          pendingCommands.append(.showWorkspace)
        case menuAgentDefaultsID:
          pendingCommands.append(.showAgentDefaults)
        case menuLogsID:
          pendingCommands.append(.showLogs)
        case menuSettingsID:
          pendingCommands.append(.showSettings)
        default:
          break
        }
        return 0
      case UINT(WM_SIZE):
        if wParam == WPARAM(SIZE_MINIMIZED) {
          _ = ShowWindow(window, SW_HIDE)  // minimize to tray
        } else {
          WindowsTaskInspector.layout(window, chat: chat)
        }
        return 0
      case trayCallbackMessage:
        if lParam == LPARAM(WM_LBUTTONDBLCLK) {
          _ = ShowWindow(window, SW_SHOW)
          _ = ShowWindow(window, SW_RESTORE)
          _ = SetForegroundWindow(window)
        }
        return 0
      case UINT(WM_CLOSE):
        _ = DestroyWindow(window)
        return 0
      case UINT(WM_DESTROY):
        removeTrayIcon()
        Self.window = nil
        PostQuitMessage(0)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    // MARK: - Creation helpers

    private static func registerWindowClass(_ instance: HINSTANCE) {
      windowClassName.withCString(encodedAs: UTF16.self) { className in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsMainWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(nil, resourcePointer(standardResourceID))
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(standardResourceID))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = className
        _ = RegisterClassW(&windowClass)
      }
    }

    private static func installMenu(_ window: HWND?) {
      let fileMenu = CreatePopupMenu()
      appendMenuItem(fileMenu, UINT(MF_STRING), menuExitID, "退出")
      let actionsMenu = CreatePopupMenu()
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuRefreshID, "刷新任务")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuStartServiceID, "启动服务")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuApprovalsID, "待处理审批…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuProjectsID, "项目管理…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuAgentsID, "Agent 管理…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuWorkspaceID, "Direct 工作区…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuAgentDefaultsID, "Agent 默认模型…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuLogsID, "任务日志…")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuSettingsID, "设置…")
      let menuBar = CreateMenu()
      appendPopup(menuBar, fileMenu, "文件")
      appendPopup(menuBar, actionsMenu, "操作")
      _ = SetMenu(window, menuBar)
    }

    private static func appendMenuItem(
      _ menu: HMENU?, _ flags: UINT, _ id: UINT_PTR, _ text: String
    ) {
      text.withCString(encodedAs: UTF16.self) {
        _ = AppendMenuW(menu, flags, id, $0)
      }
    }

    private static func appendPopup(_ menuBar: HMENU?, _ popup: HMENU?, _ text: String) {
      guard let popup else { return }
      let id = UINT_PTR(UInt(bitPattern: Int(bitPattern: popup)))
      text.withCString(encodedAs: UTF16.self) {
        _ = AppendMenuW(menuBar, UINT(MF_POPUP | MF_STRING), id, $0)
      }
    }

    // MARK: - Tray icon

    private static func installTrayIcon(_ window: HWND?) {
      guard let window else { return }
      var data = NOTIFYICONDATAW()
      data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
      data.hWnd = window
      data.uID = UINT(1)
      data.uFlags = UINT(trayNIFMessage | trayNIFIcon | trayNIFTip)
      data.uCallbackMessage = trayCallbackMessage
      data.hIcon = LoadIconW(nil, resourcePointer(standardResourceID))
      copyTip("Codex Bridge", into: &data)
      _ = Shell_NotifyIconW(trayNIMAdd, &data)
      trayData = data
    }

    private static func copyTip(_ tip: String, into data: inout NOTIFYICONDATAW) {
      withUnsafeMutableBytes(of: &data) { raw in
        let target = raw.baseAddress!
          .advanced(by: trayTipOffset)
          .assumingMemoryBound(to: WCHAR.self)
        tip.withCString(encodedAs: UTF16.self) { source in
          var index = 0
          while source[index] != 0 && index < 127 {
            target[index] = source[index]
            index += 1
          }
          target[index] = 0
        }
      }
    }

    private static func removeTrayIcon() {
      if var data = trayData {
        _ = Shell_NotifyIconW(trayNIMDelete, &data)
      }
      trayData = nil
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
