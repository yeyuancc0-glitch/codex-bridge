#if os(Windows)
  import WinSDK

  enum WindowsEmbeddedPages {
    nonisolated(unsafe) private static var projectsSection = 0
    nonisolated(unsafe) private static var connectionsSection = 1
    nonisolated(unsafe) private static var settingsSection = 0

    static func prepare(in parent: HWND?) {
      WindowsProjectManagementWindow.show(owner: parent)
      embed(WindowsProjectManagementWindow.window, in: parent)
      WindowsLogWindow.show(owner: parent)
      embed(WindowsLogWindow.window, in: parent)
      WindowsAgentManagementWindow.show(owner: parent)
      embed(WindowsAgentManagementWindow.window, in: parent)
      WindowsSettingsWindow.show(owner: parent)
      embed(WindowsSettingsWindow.window, in: parent)
      WindowsWorkspaceWindow.show(owner: parent)
      embed(WindowsWorkspaceWindow.window, in: parent)
      WindowsAgentDefaultsWindow.show(owner: parent)
      embed(WindowsAgentDefaultsWindow.window, in: parent)
      WindowsConnectionWindow.show(owner: parent)
      embed(WindowsConnectionWindow.window, in: parent)
      WindowsEmbeddedPageTabs.create(in: parent, instance: GetModuleHandleW(nil))
      select(.overview)
    }

    static func select(_ page: WindowsMainPage) {
      WindowsUIFoundation.show(
        WindowsProjectManagementWindow.window,
        page == .projects && projectsSection == 0
      )
      WindowsUIFoundation.show(
        WindowsWorkspaceWindow.window,
        page == .projects && projectsSection == 1
      )
      WindowsUIFoundation.show(WindowsLogWindow.window, page == .logs)
      WindowsUIFoundation.show(
        WindowsAgentManagementWindow.window,
        page == .connections && connectionsSection == 1
      )
      WindowsUIFoundation.show(
        WindowsConnectionWindow.window,
        page == .connections && connectionsSection == 0
      )
      WindowsUIFoundation.show(
        WindowsSettingsWindow.window,
        page == .settings && settingsSection == 0
      )
      WindowsUIFoundation.show(
        WindowsAgentDefaultsWindow.window,
        page == .settings && settingsSection == 1
      )
      WindowsEmbeddedPageTabs.apply(page: page, selectedIndex: selectedSection(for: page))
    }

    static func selectSection(page: WindowsMainPage, index: Int) {
      guard index == 0 || index == 1 else { return }
      switch page {
      case .projects: projectsSection = index
      case .connections: connectionsSection = index
      case .settings: settingsSection = index
      case .overview, .workbench, .logs: return
      }
      select(page)
    }

    static func layout(page: WindowsMainPage, in bounds: RECT) {
      let contentBounds: RECT
      switch page {
      case .projects, .connections, .settings:
        contentBounds = WindowsEmbeddedPageTabs.layout(in: bounds)
      case .overview, .workbench, .logs:
        contentBounds = bounds
      }
      guard let window = window(for: page) else { return }
      _ = MoveWindow(
        window,
        contentBounds.left,
        contentBounds.top,
        max(Int32(0), contentBounds.right - contentBounds.left),
        max(Int32(0), contentBounds.bottom - contentBounds.top),
        true
      )
    }

    private static func window(for page: WindowsMainPage) -> HWND? {
      switch page {
      case .projects:
        projectsSection == 0 ? WindowsProjectManagementWindow.window : WindowsWorkspaceWindow.window
      case .logs: WindowsLogWindow.window
      case .connections:
        connectionsSection == 0
          ? WindowsConnectionWindow.window : WindowsAgentManagementWindow.window
      case .settings:
        settingsSection == 0 ? WindowsSettingsWindow.window : WindowsAgentDefaultsWindow.window
      case .overview, .workbench: nil
      }
    }

    private static func selectedSection(for page: WindowsMainPage) -> Int {
      switch page {
      case .projects: projectsSection
      case .connections: connectionsSection
      case .settings: settingsSection
      case .overview, .workbench, .logs: 0
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
