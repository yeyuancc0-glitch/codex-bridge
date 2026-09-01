#if os(Windows)
  import WinSDK

  enum WindowLayout {
    static let navigationWidth = 220
    static let inspectorIdealWidth = 400
    static let inspectorMinimumWidth = 280
    static let windowWidth = 1180
    static let windowHeight = 760
  }

  enum WindowsMainWindow {
    private static let windowClassName = WindowsApplicationIdentity.mainWindowClassName
    private static let windowTitle = "Codex Bridge"
    private static let defaultPosition = Int32(bitPattern: 0x8000_0000)
    private static let standardResourceID = 32_512
    private static let timerID: UINT_PTR = 1
    private static let timerIntervalMs: UINT = 250

    nonisolated(unsafe) private static var pendingCommands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var selectedPage = WindowsMainPage.overview
    nonisolated(unsafe) private static var chatBounds = RECT()
    nonisolated(unsafe) static var chat: WindowsChatWebView?
    nonisolated(unsafe) static var window: HWND?

    static func create() -> HWND? {
      WindowsUIFoundation.initialize()
      let instance = GetModuleHandleW(nil)!
      registerWindowClass(instance)
      let created = createWindow(instance: instance)
      guard let window = created else {
        showCreationFailure(GetLastError())
        return nil
      }
      self.window = window
      WindowsNavigationSidebar.create(in: window, instance: instance)
      WindowsPageHeader.create(in: window, instance: instance)
      WindowsOverviewPane.create(in: window, instance: instance)
      WindowsTaskInspector.create(in: window, instance: instance)
      WindowsBrowserToolbar.create(in: window, instance: instance)
      WindowsEmbeddedPages.prepare(in: window)
      WindowsMainWindowChrome.install(on: window)
      _ = SetTimer(window, timerID, timerIntervalMs, nil)
      selectPage(.overview)
      layout()
      _ = ShowWindow(window, SW_SHOW)
      return window
    }

    static func enqueue(_ command: MainWindowCommand) {
      pendingCommands.append(command)
    }

    static func currentWindow() -> HWND? { window }

    static func currentPage() -> WindowsMainPage { selectedPage }

    static func workbenchChatBounds() -> RECT { chatBounds }

    static func takePendingCommands() -> [MainWindowCommand] {
      let commands = pendingCommands
      pendingCommands.removeAll()
      return commands
    }

    static func selectPage(_ page: WindowsMainPage) {
      selectedPage = page
      WindowsNavigationSidebar.select(page)
      WindowsPageHeader.apply(page: page)
      WindowsOverviewPane.setVisible(page == .overview)
      WindowsTaskInspector.setVisible(page == .workbench)
      WindowsTaskInspector.setChatPlaceholderPageVisible(page == .workbench)
      WindowsBrowserToolbar.setVisible(page == .workbench)
      WindowsEmbeddedPages.select(page)
      chat?.setVisible(page == .workbench)
      layout()
    }

    static func updateNavigation(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) {
      WindowsNavigationSidebar.update(
        state: workbench.connectionState,
        taskCount: workbench.taskCount,
        approvalCount: workbench.pendingApprovalCount,
        projectCount: management.project.rows.count
      )
      if selectedPage == .connections {
        WindowsPageHeader.apply(
          page: .connections,
          statusDetail:
            "本地 MCP：\(workbench.mcpAddress) · \(management.agent.installationRows.count) 个 Agent"
        )
      }
    }

    static func updateOverview(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) {
      WindowsOverviewPane.apply(
        WindowsOverviewDisplay(
          connectionState: workbench.connectionState,
          runningTaskCount: workbench.runningTaskCount,
          pendingApprovalCount: workbench.pendingApprovalCount,
          projectCount: management.project.rows.count,
          agentCount: management.agent.installationRows.count,
          taskCount: workbench.taskCount,
          mcpAddress: workbench.mcpAddress,
          recentTaskRows: Array(workbench.taskRows.prefix(4)),
          detailText: workbench.detailText
        )
      )
    }

    static func setStatusText(_ text: String) {
      WindowsTaskInspector.setStatusText(text)
    }

    static func setTaskRows(_ rows: [String], selectedIndex: Int?) {
      WindowsTaskInspector.setTaskRows(rows, selectedIndex: selectedIndex)
    }

    static func setChatPlaceholder(_ text: String?) {
      WindowsTaskInspector.setChatPlaceholder(text)
      WindowsTaskInspector.setChatPlaceholderPageVisible(selectedPage == .workbench)
    }

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        if WindowsMainWindowChrome.isExitCommand(wParam) {
          _ = DestroyWindow(window)
          return 0
        }
        let command =
          WindowsNavigationSidebar.command(for: wParam)
          ?? WindowsPageHeader.command(for: wParam)
          ?? WindowsOverviewPane.command(for: wParam)
          ?? WindowsBrowserToolbar.command(for: wParam)
          ?? WindowsTaskInspector.command(for: wParam)
          ?? WindowsMainWindowChrome.command(for: wParam)
        if let command { pendingCommands.append(command) }
        return 0
      case UINT(WM_SIZE):
        if wParam == WPARAM(SIZE_MINIMIZED) {
          _ = ShowWindow(window, SW_HIDE)
        } else {
          layout()
        }
        return 0
      case WindowsMainWindowChrome.trayCallbackMessage:
        _ = WindowsMainWindowChrome.handleTrayMessage(lParam, window: window)
        return 0
      case UINT(WM_CLOSE):
        _ = DestroyWindow(window)
        return 0
      case UINT(WM_DESTROY):
        WindowsMainWindowChrome.removeTrayIcon()
        WindowsUIFoundation.shutdown()
        Self.window = nil
        PostQuitMessage(0)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    private static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let navigationWidth = Int32(WindowLayout.navigationWidth)
      WindowsNavigationSidebar.layout(height: area.bottom, width: navigationWidth)
      let detailBounds = RECT(
        left: navigationWidth,
        top: area.top,
        right: area.right,
        bottom: area.bottom
      )
      let contentBounds = WindowsPageHeader.layout(in: detailBounds)
      WindowsOverviewPane.layout(in: contentBounds)
      if selectedPage == .workbench {
        layoutWorkbench(in: contentBounds)
      } else {
        WindowsEmbeddedPages.layout(page: selectedPage, in: contentBounds)
      }
    }

    private static func layoutWorkbench(in bounds: RECT) {
      let width = bounds.right - bounds.left
      let inspectorWidth = min(
        Int32(WindowLayout.inspectorIdealWidth),
        max(Int32(WindowLayout.inspectorMinimumWidth), width / 3)
      )
      let inspector = RECT(
        left: bounds.right - inspectorWidth,
        top: bounds.top,
        right: bounds.right,
        bottom: bounds.bottom
      )
      let browser = RECT(
        left: bounds.left,
        top: bounds.top,
        right: inspector.left - 1,
        bottom: bounds.bottom
      )
      chatBounds = WindowsBrowserToolbar.layout(in: browser)
      WindowsTaskInspector.layoutChatPlaceholder(in: chatBounds)
      WindowsTaskInspector.layoutInspector(in: inspector)
      chat?.resize(to: chatBounds)
    }

    private static func createWindow(instance: HINSTANCE?) -> HWND? {
      windowTitle.withCString(encodedAs: UTF16.self) { title in
        windowClassName.withCString(encodedAs: UTF16.self) { className in
          CreateWindowExW(
            0,
            className,
            title,
            DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
            defaultPosition,
            defaultPosition,
            Int32(WindowLayout.windowWidth),
            Int32(WindowLayout.windowHeight),
            nil,
            nil,
            instance,
            nil
          )
        }
      }
    }

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

    private static func showCreationFailure(_ errorCode: DWORD) {
      let message = "无法创建 Codex Bridge 主窗口。Win32 错误：\(errorCode)"
      message.withCString(encodedAs: UTF16.self) { messagePointer in
        windowTitle.withCString(encodedAs: UTF16.self) { titlePointer in
          _ = MessageBoxW(
            nil,
            messagePointer,
            titlePointer,
            UINT(MB_OK) | UINT(MB_ICONERROR)
          )
        }
      }
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
