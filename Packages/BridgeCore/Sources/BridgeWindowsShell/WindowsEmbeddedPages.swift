#if os(Windows)
  import WinSDK

  enum WindowsEmbeddedPages {
    static func prepare(in parent: HWND?) {
      WindowsProjectManagementWindow.show(owner: parent)
      embed(WindowsProjectManagementWindow.window, in: parent)
      WindowsLogWindow.show(owner: parent)
      embed(WindowsLogWindow.window, in: parent)
      WindowsAgentManagementWindow.show(owner: parent)
      embed(WindowsAgentManagementWindow.window, in: parent)
      WindowsSettingsWindow.show(owner: parent)
      embed(WindowsSettingsWindow.window, in: parent)
      select(.overview)
    }

    static func select(_ page: WindowsMainPage) {
      WindowsUIFoundation.show(
        WindowsProjectManagementWindow.window,
        page == .projects
      )
      WindowsUIFoundation.show(WindowsLogWindow.window, page == .logs)
      WindowsUIFoundation.show(
        WindowsAgentManagementWindow.window,
        page == .connections
      )
      WindowsUIFoundation.show(WindowsSettingsWindow.window, page == .settings)
    }

    static func layout(page: WindowsMainPage, in bounds: RECT) {
      guard let window = window(for: page) else { return }
      _ = MoveWindow(
        window,
        bounds.left,
        bounds.top,
        max(Int32(0), bounds.right - bounds.left),
        max(Int32(0), bounds.bottom - bounds.top),
        true
      )
    }

    private static func window(for page: WindowsMainPage) -> HWND? {
      switch page {
      case .projects: WindowsProjectManagementWindow.window
      case .logs: WindowsLogWindow.window
      case .connections: WindowsAgentManagementWindow.window
      case .settings: WindowsSettingsWindow.window
      case .overview, .workbench: nil
      }
    }

    private static func embed(_ window: HWND?, in parent: HWND?) {
      guard let window, let parent else { return }
      _ = SetParent(window, parent)
      let topLevelBits =
        DWORD(WS_CAPTION) | DWORD(WS_THICKFRAME)
        | DWORD(WS_MINIMIZEBOX) | DWORD(WS_MAXIMIZEBOX)
        | DWORD(WS_SYSMENU) | DWORD(WS_POPUP)
      let topLevelStyle = LONG(bitPattern: topLevelBits)
      let childStyle = LONG(bitPattern: DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN))
      let style = GetWindowLongW(window, GWL_STYLE)
      _ = SetWindowLongW(
        window,
        GWL_STYLE,
        (style & ~topLevelStyle) | childStyle
      )
      let exStyle = GetWindowLongW(window, GWL_EXSTYLE)
      let toolWindowStyle = LONG(bitPattern: DWORD(WS_EX_TOOLWINDOW))
      _ = SetWindowLongW(window, GWL_EXSTYLE, exStyle & ~toolWindowStyle)
      _ = SetWindowPos(
        window,
        nil,
        0,
        0,
        0,
        0,
        UINT(SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED)
      )
      WindowsUIFoundation.applyBodyFontRecursively(to: window)
      _ = ShowWindow(window, SW_HIDE)
    }
  }
#endif
