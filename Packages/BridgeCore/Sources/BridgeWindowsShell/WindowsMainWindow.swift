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

  enum MainWindowCommand: Equatable {
    case refreshTasks
    case startService
  }

  /// Owns the top-level window, child controls, menu and tray icon. All state
  /// is confined to the message-loop thread; `nonisolated(unsafe)` marks the
  /// statics the plain-C window procedure touches.
  enum WindowsMainWindow {
    private static let windowClassName = "CodexBridgeMainWindow"
    private static let windowTitle = "Codex Bridge"

    // CW_USEDEFAULT ((int)0x80000000); cast macros are not imported by WinSDK.
    private static let defaultPosition = Int32(bitPattern: 0x8000_0000)
    // MAKEINTRESOURCE(32512): IDI_APPLICATION / IDC_ARROW.
    private static let standardResourceID = 32_512

    private static let menuExitID: UINT_PTR = 1001
    private static let menuRefreshID: UINT_PTR = 1002
    private static let menuStartServiceID: UINT_PTR = 1003
    private static let listBoxControlID = 2001
    private static let statusControlID = 2002
    private static let chatPlaceholderControlID = 2003
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

    nonisolated(unsafe) private static var listBox: HWND?
    nonisolated(unsafe) private static var statusStatic: HWND?
    nonisolated(unsafe) private static var chatPlaceholder: HWND?
    nonisolated(unsafe) private static var pendingCommands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var trayData: NOTIFYICONDATAW?
    nonisolated(unsafe) static var chat: WindowsChatWebView?

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
      listBox = createChild(
        "LISTBOX", "", DWORD(WS_VSCROLL), DWORD(WS_EX_CLIENTEDGE),
        window, instance, listBoxControlID
      )
      statusStatic = createChild(
        "STATIC", "", 0, 0, window, instance, statusControlID
      )
      chatPlaceholder = createChild(
        "STATIC", "正在加载聊天页…", 0, 0, window, instance, chatPlaceholderControlID
      )
      installMenu(window)
      installTrayIcon(window)
      _ = SetTimer(window, timerID, timerIntervalMs, nil)
      _ = ShowWindow(window, SW_SHOW)
      layout(window)
      return window
    }

    static func takePendingCommands() -> [MainWindowCommand] {
      let commands = pendingCommands
      pendingCommands.removeAll()
      return commands
    }

    static func setStatusText(_ text: String) {
      setText(statusStatic, text)
    }

    static func setTaskRows(_ rows: [String]) {
      guard let listBox else { return }
      _ = SendMessageW(listBox, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { text in
          let pointer = LPARAM(Int(bitPattern: UnsafeRawPointer(text)))
          _ = SendMessageW(listBox, UINT(LB_ADDSTRING), 0, pointer)
        }
      }
    }

    /// nil hides the placeholder (chat page active).
    static func setChatPlaceholder(_ text: String?) {
      guard let chatPlaceholder else { return }
      if let text {
        setText(chatPlaceholder, text)
        _ = ShowWindow(chatPlaceholder, SW_SHOW)
      } else {
        _ = ShowWindow(chatPlaceholder, SW_HIDE)
      }
    }

    // MARK: - Window procedure

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        switch wParam & 0xFFFF {
        case menuExitID:
          _ = DestroyWindow(window)
        case menuRefreshID:
          pendingCommands.append(.refreshTasks)
        case menuStartServiceID:
          pendingCommands.append(.startService)
        default:
          break
        }
        return 0
      case UINT(WM_SIZE):
        if wParam == WPARAM(SIZE_MINIMIZED) {
          _ = ShowWindow(window, SW_HIDE)  // minimize to tray
        } else {
          layout(window)
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
        PostQuitMessage(0)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    private static func layout(_ window: HWND?) {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let sidebar = Int32(WindowLayout.sidebarWidth)
      let inset = Int32(WindowLayout.statusInset)
      _ = MoveWindow(listBox, 0, 0, sidebar, height, true)
      _ = MoveWindow(
        statusStatic, sidebar + inset, inset,
        width - sidebar - inset * 2, Int32(WindowLayout.statusHeight), true
      )
      let chatTop = Int32(WindowLayout.chatTopInset)
      _ = MoveWindow(chatPlaceholder, sidebar, chatTop, width - sidebar, height - chatTop, true)
      chat?.resize(
        to: RECT(left: sidebar, top: chatTop, right: width, bottom: height)
      )
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

    private static func createChild(
      _ className: String, _ text: String, _ style: DWORD, _ exStyle: DWORD,
      _ parent: HWND?, _ instance: HINSTANCE?, _ id: Int
    ) -> HWND? {
      className.withCString(encodedAs: UTF16.self) { classPointer -> HWND? in
        text.withCString(encodedAs: UTF16.self) { textPointer in
          CreateWindowExW(
            exStyle, classPointer, textPointer,
            DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
            0, 0, 0, 0, parent, HMENU(bitPattern: id), instance, nil
          )
        }
      }
    }

    private static func installMenu(_ window: HWND?) {
      let fileMenu = CreatePopupMenu()
      appendMenuItem(fileMenu, UINT(MF_STRING), menuExitID, "退出")
      let actionsMenu = CreatePopupMenu()
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuRefreshID, "刷新任务")
      appendMenuItem(actionsMenu, UINT(MF_STRING), menuStartServiceID, "启动服务")
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

    private static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) {
        _ = SetWindowTextW(target, $0)
      }
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
