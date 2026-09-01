#if os(Windows)
  import WinSDK

  enum WindowsEmbeddedPageTabs {
    private static let firstID = 2301
    private static let secondID = 2302

    nonisolated(unsafe) private static var firstButton: HWND?
    nonisolated(unsafe) private static var secondButton: HWND?
    nonisolated(unsafe) private static var page: WindowsMainPage?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      firstButton = WindowsUIFoundation.createChild(
        "BUTTON", style: DWORD(BS_AUTORADIOBUTTON) | DWORD(WS_GROUP),
        parent: parent, instance: instance, id: firstID)
      secondButton = WindowsUIFoundation.createChild(
        "BUTTON", style: DWORD(BS_AUTORADIOBUTTON),
        parent: parent, instance: instance, id: secondID)
      setVisible(false)
    }

    static func apply(page: WindowsMainPage, selectedIndex: Int) {
      self.page = page
      let labels: (String, String)? =
        switch page {
        case .projects: ("访问与权限", "Direct / Skills / Threads")
        case .connections: ("MCP 客户端", "Agent 安装")
        case .settings: ("Codex 与审批", "Agent 默认")
        case .overview, .workbench, .logs: nil
        }
      guard let labels else {
        setVisible(false)
        return
      }
      WindowsUIFoundation.setText(firstButton, labels.0)
      WindowsUIFoundation.setText(secondButton, labels.1)
      _ = SendMessageW(
        firstButton, UINT(BM_SETCHECK), WPARAM(selectedIndex == 0 ? BST_CHECKED : BST_UNCHECKED), 0)
      _ = SendMessageW(
        secondButton, UINT(BM_SETCHECK), WPARAM(selectedIndex == 1 ? BST_CHECKED : BST_UNCHECKED), 0
      )
      setVisible(true)
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      guard (wParam >> 16) & 0xFFFF == WPARAM(BN_CLICKED), let page else { return nil }
      let index: Int
      switch wParam & 0xFFFF {
      case WPARAM(firstID): index = 0
      case WPARAM(secondID): index = 1
      default: return nil
      }
      switch page {
      case .projects: return .selectProjectsSection(index: index)
      case .connections: return .selectConnectionsSection(index: index)
      case .settings: return .selectSettingsSection(index: index)
      case .overview, .workbench, .logs: return nil
      }
    }

    static func layout(in bounds: RECT) -> RECT {
      let left = bounds.left + 12
      let top = bounds.top + 8
      _ = MoveWindow(firstButton, left, top, 170, 28, true)
      _ = MoveWindow(secondButton, left + 178, top, 210, 28, true)
      return RECT(
        left: bounds.left, top: bounds.top + 44, right: bounds.right, bottom: bounds.bottom)
    }

    private static func setVisible(_ visible: Bool) {
      WindowsUIFoundation.show(firstButton, visible)
      WindowsUIFoundation.show(secondButton, visible)
    }
  }
#endif
