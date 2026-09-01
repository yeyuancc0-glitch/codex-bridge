#if os(Windows)
  import WinSDK

  enum WindowsMainPage: Int, CaseIterable, Sendable {
    case overview
    case workbench
    case projects
    case logs
    case connections
    case settings

    var title: String {
      switch self {
      case .overview: "概览"
      case .workbench: "工作台"
      case .projects: "项目"
      case .logs: "日志"
      case .connections: "连接"
      case .settings: "设置"
      }
    }

    var subtitle: String {
      switch self {
      case .overview: "全景监控后台 Service、本地 MCP 与任务执行状态。"
      case .workbench: "在 ChatGPT 与本机任务证据之间保持同一工作上下文。"
      case .projects: "管理项目登记、访问权限与执行边界。"
      case .logs: "检查任务事件、命令、文件与错误证据。"
      case .connections: "管理本地 MCP 通道与本机 Agent 引擎。"
      case .settings: "配置模型、执行偏好、安全策略与全局指令。"
      }
    }
  }

  enum WindowsNavigationSidebar {
    private static let titleID = 1201
    private static let listID = 1202
    private static let footerID = 1203

    nonisolated(unsafe) private static var title: HWND?
    nonisolated(unsafe) private static var list: HWND?
    nonisolated(unsafe) private static var footer: HWND?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      title = WindowsUIFoundation.createChild(
        "STATIC",
        text: "Codex Bridge",
        style: DWORD(SS_LEFT),
        parent: parent,
        instance: instance,
        id: titleID
      )
      WindowsUIFoundation.applyTitleFont(to: title)
      list = WindowsUIFoundation.createChild(
        "LISTBOX",
        style: DWORD(LBS_NOTIFY) | DWORD(LBS_NOINTEGRALHEIGHT),
        parent: parent,
        instance: instance,
        id: listID
      )
      footer = WindowsUIFoundation.createChild(
        "STATIC",
        text: "● 未连接",
        style: DWORD(SS_LEFT),
        parent: parent,
        instance: instance,
        id: footerID
      )
      populate(taskCount: 0, approvalCount: 0, projectCount: 0)
      _ = SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(WindowsMainPage.overview.rawValue), 0)
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      guard id == WPARAM(listID), notification == WPARAM(LBN_SELCHANGE), let list else {
        return nil
      }
      let selected = SendMessageW(list, UINT(LB_GETCURSEL), 0, 0)
      guard WindowsMainPage(rawValue: Int(selected)) != nil else { return nil }
      return .selectPage(index: Int(selected))
    }

    static func select(_ page: WindowsMainPage) {
      _ = SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(page.rawValue), 0)
    }

    static func update(
      state: WindowsWorkbenchDisplay.ConnectionState,
      taskCount: Int,
      approvalCount: Int,
      projectCount: Int
    ) {
      populate(
        taskCount: taskCount,
        approvalCount: approvalCount,
        projectCount: projectCount
      )
      let status: String
      switch state {
      case .idle: status = "● 未连接"
      case .connecting: status = "● 正在连接"
      case .connected: status = "● 已连接"
      case .unavailable: status = "● 不可用"
      }
      WindowsUIFoundation.setText(footer, status)
    }

    static func layout(height: Int32, width: Int32) {
      let padding = Int32(16)
      _ = MoveWindow(title, padding, 18, width - padding * 2, 30, true)
      _ = MoveWindow(list, 8, 58, width - 16, max(0, height - 116), true)
      _ = MoveWindow(footer, padding, max(0, height - 42), width - padding * 2, 24, true)
    }

    private static func populate(taskCount: Int, approvalCount: Int, projectCount: Int) {
      guard let list else { return }
      let selected = SendMessageW(list, UINT(LB_GETCURSEL), 0, 0)
      let workbenchSuffix =
        approvalCount > 0
        ? "  ·  \(approvalCount) 项待审批"
        : (taskCount > 0 ? "  ·  \(taskCount) 个任务" : "")
      let projectSuffix = projectCount > 0 ? "  ·  \(projectCount)" : ""
      let rows = [
        WindowsMainPage.overview.title,
        WindowsMainPage.workbench.title + workbenchSuffix,
        WindowsMainPage.projects.title + projectSuffix,
        WindowsMainPage.logs.title,
        WindowsMainPage.connections.title,
        WindowsMainPage.settings.title,
      ]
      _ = SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { pointer in
          _ = SendMessageW(
            list,
            UINT(LB_ADDSTRING),
            0,
            LPARAM(Int(bitPattern: UnsafeRawPointer(pointer)))
          )
        }
      }
      let next = selected >= 0 ? selected : LRESULT(WindowsMainPage.overview.rawValue)
      _ = SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(next), 0)
    }
  }
#endif
