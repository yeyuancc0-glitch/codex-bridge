#if os(Windows)
  import WinSDK

  enum WindowsMainWindowChrome {
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

    private static let trayNIMAdd: DWORD = 0
    private static let trayNIMDelete: DWORD = 2
    private static let trayNIFMessage: DWORD = 0x01
    private static let trayNIFIcon: DWORD = 0x02
    private static let trayNIFTip: DWORD = 0x04
    private static let trayTipOffset = 40
    static let trayCallbackMessage: UINT = 0x8000 + 2
    private static let standardResourceID = 32_512

    nonisolated(unsafe) private static var trayData: NOTIFYICONDATAW?

    static func install(on window: HWND?) {
      installMenu(on: window)
      installTrayIcon(on: window)
    }

    static func isExitCommand(_ wParam: WPARAM) -> Bool {
      wParam & 0xFFFF == menuExitID
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      switch wParam & 0xFFFF {
      case menuRefreshID: .refreshCurrentPage
      case menuStartServiceID: .startService
      case menuApprovalsID: .showApprovals
      case menuProjectsID: .selectPage(index: WindowsMainPage.projects.rawValue)
      case menuAgentsID: .selectPage(index: WindowsMainPage.connections.rawValue)
      case menuWorkspaceID: .showWorkspace
      case menuAgentDefaultsID: .showAgentDefaults
      case menuLogsID: .selectPage(index: WindowsMainPage.logs.rawValue)
      case menuSettingsID: .selectPage(index: WindowsMainPage.settings.rawValue)
      default: nil
      }
    }

    static func handleTrayMessage(_ lParam: LPARAM, window: HWND?) -> Bool {
      guard lParam == LPARAM(WM_LBUTTONDBLCLK) else { return false }
      _ = ShowWindow(window, SW_SHOW)
      _ = ShowWindow(window, SW_RESTORE)
      _ = SetForegroundWindow(window)
      return true
    }

    static func removeTrayIcon() {
      if var data = trayData {
        _ = Shell_NotifyIconW(trayNIMDelete, &data)
      }
      trayData = nil
    }

    private static func installMenu(on window: HWND?) {
      let fileMenu = CreatePopupMenu()
      appendMenuItem(fileMenu, menuExitID, "退出")
      let actionsMenu = CreatePopupMenu()
      appendMenuItem(actionsMenu, menuRefreshID, "刷新当前页面")
      appendMenuItem(actionsMenu, menuStartServiceID, "启动服务")
      appendMenuItem(actionsMenu, menuApprovalsID, "待处理审批")
      appendMenuItem(actionsMenu, menuProjectsID, "项目")
      appendMenuItem(actionsMenu, menuAgentsID, "连接与 Agent")
      appendMenuItem(actionsMenu, menuWorkspaceID, "Direct 工作区")
      appendMenuItem(actionsMenu, menuAgentDefaultsID, "Agent 默认模型")
      appendMenuItem(actionsMenu, menuLogsID, "日志")
      appendMenuItem(actionsMenu, menuSettingsID, "设置")
      let menuBar = CreateMenu()
      appendPopup(menuBar, fileMenu, "文件")
      appendPopup(menuBar, actionsMenu, "操作")
      _ = SetMenu(window, menuBar)
    }

    private static func appendMenuItem(_ menu: HMENU?, _ id: UINT_PTR, _ text: String) {
      text.withCString(encodedAs: UTF16.self) {
        _ = AppendMenuW(menu, UINT(MF_STRING), id, $0)
      }
    }

    private static func appendPopup(_ menu: HMENU?, _ popup: HMENU?, _ text: String) {
      guard let popup else { return }
      let id = UINT_PTR(UInt(bitPattern: Int(bitPattern: popup)))
      text.withCString(encodedAs: UTF16.self) {
        _ = AppendMenuW(menu, UINT(MF_POPUP | MF_STRING), id, $0)
      }
    }

    private static func installTrayIcon(on window: HWND?) {
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

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
