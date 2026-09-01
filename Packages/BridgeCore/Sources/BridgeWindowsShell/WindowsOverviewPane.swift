#if os(Windows)
  import WinSDK

  struct WindowsOverviewDisplay: Equatable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let runningTaskCount: Int
    let pendingApprovalCount: Int
    let projectCount: Int
    let agentCount: Int
    let taskCount: Int
    let mcpAddress: String
    let recentTaskRows: [String]
    let detailText: String?
  }

  enum WindowsOverviewPane {
    private static let attentionID = 1401
    private static let attentionButtonID = 1402
    private static let metricsLabelID = 1403
    private static let runningID = 1410
    private static let approvalsID = 1411
    private static let projectsID = 1412
    private static let agentsID = 1413
    private static let tasksID = 1414
    private static let topologyLabelID = 1420
    private static let topologyID = 1421
    private static let recentLabelID = 1430
    private static let recentListID = 1431

    nonisolated(unsafe) private static var attention: HWND?
    nonisolated(unsafe) private static var attentionButton: HWND?
    nonisolated(unsafe) private static var metricsLabel: HWND?
    nonisolated(unsafe) private static var metricButtons: [HWND?] = []
    nonisolated(unsafe) private static var topologyLabel: HWND?
    nonisolated(unsafe) private static var topology: HWND?
    nonisolated(unsafe) private static var recentLabel: HWND?
    nonisolated(unsafe) private static var recentList: HWND?
    nonisolated(unsafe) private static var pageVisible = true
    nonisolated(unsafe) private static var attentionCommand: MainWindowCommand =
      .selectPage(index: WindowsMainPage.workbench.rawValue)

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      attention = WindowsUIFoundation.createChild(
        "STATIC",
        text: "当前没有需要立即处理的事项。",
        style: DWORD(SS_LEFT),
        exStyle: DWORD(WS_EX_CLIENTEDGE),
        parent: parent,
        instance: instance,
        id: attentionID
      )
      attentionButton = WindowsUIFoundation.createChild(
        "BUTTON",
        text: "立即处理",
        style: DWORD(BS_PUSHBUTTON),
        parent: parent,
        instance: instance,
        id: attentionButtonID
      )
      metricsLabel = sectionLabel(
        "关键指标", parent: parent, instance: instance, id: metricsLabelID)
      metricButtons = [
        metricButton(parent, instance, runningID),
        metricButton(parent, instance, approvalsID),
        metricButton(parent, instance, projectsID),
        metricButton(parent, instance, agentsID),
        metricButton(parent, instance, tasksID),
      ]
      topologyLabel = sectionLabel(
        "连接与服务拓扑全景", parent: parent, instance: instance, id: topologyLabelID)
      topology = WindowsUIFoundation.createChild(
        "STATIC",
        style: DWORD(SS_LEFT),
        exStyle: DWORD(WS_EX_CLIENTEDGE),
        parent: parent,
        instance: instance,
        id: topologyID
      )
      recentLabel = sectionLabel(
        "最近任务", parent: parent, instance: instance, id: recentLabelID)
      recentList = WindowsUIFoundation.createChild(
        "LISTBOX",
        style: DWORD(LBS_NOTIFY) | DWORD(LBS_NOINTEGRALHEIGHT) | DWORD(WS_VSCROLL),
        exStyle: DWORD(WS_EX_CLIENTEDGE),
        parent: parent,
        instance: instance,
        id: recentListID
      )
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      if id == WPARAM(attentionButtonID), notification == WPARAM(BN_CLICKED) {
        return attentionCommand
      }
      if notification == WPARAM(BN_CLICKED) {
        switch id {
        case WPARAM(runningID), WPARAM(tasksID):
          return .selectPage(index: WindowsMainPage.workbench.rawValue)
        case WPARAM(approvalsID):
          return .showApprovals
        case WPARAM(projectsID):
          return .selectPage(index: WindowsMainPage.projects.rawValue)
        case WPARAM(agentsID):
          return .selectPage(index: WindowsMainPage.connections.rawValue)
        default:
          break
        }
      }
      if id == WPARAM(recentListID), notification == WPARAM(LBN_DBLCLK), let recentList {
        let selected = SendMessageW(recentList, UINT(LB_GETCURSEL), 0, 0)
        guard selected >= 0 else { return nil }
        return .openRecentTask(index: Int(selected))
      }
      return nil
    }

    static func apply(_ display: WindowsOverviewDisplay) {
      let needsAttention = display.pendingApprovalCount > 0 || display.detailText != nil
      let attentionText: String
      if display.pendingApprovalCount > 0 {
        attentionText = "需要处理：\(display.pendingApprovalCount) 项本机审批正在阻断任务。"
        attentionCommand = .showApprovals
      } else if let detail = display.detailText {
        attentionText = "连接需要检查：\(detail)"
        attentionCommand = .selectPage(index: WindowsMainPage.connections.rawValue)
      } else {
        attentionText = "当前没有需要立即处理的事项。"
        attentionCommand = .selectPage(index: WindowsMainPage.workbench.rawValue)
      }
      WindowsUIFoundation.setText(attention, attentionText)
      WindowsUIFoundation.show(attentionButton, pageVisible && needsAttention)

      let values = [
        "运行中任务\r\n\(display.runningTaskCount)\r\n当前执行队列",
        "待审批项\r\n\(display.pendingApprovalCount)\r\n本机安全决定",
        "注册项目\r\n\(display.projectCount)\r\n本地目录",
        "本机 Agent\r\n\(display.agentCount)\r\n已登记实例",
        "任务总数\r\n\(display.taskCount)\r\n任务历史",
      ]
      for (button, text) in zip(metricButtons, values) {
        WindowsUIFoundation.setText(button, text)
      }
      WindowsUIFoundation.setText(
        topology,
        "后台常驻 Service\t\(connectionLabel(display.connectionState))\r\n"
          + "本地 MCP 通道\t\(display.mcpAddress)\r\n"
          + "远程 Secure Tunnel\tWindows 暂不支持\r\n"
          + "本机 Agent 引擎\t\(display.agentCount) 个已登记"
      )
      WindowsAuxiliaryControlSupport.setRows(
        recentList,
        rows: display.recentTaskRows,
        selectedIndex: nil
      )
      WindowsUIFoundation.show(recentLabel, pageVisible && !display.recentTaskRows.isEmpty)
      WindowsUIFoundation.show(recentList, pageVisible && !display.recentTaskRows.isEmpty)
    }

    static func setVisible(_ visible: Bool) {
      pageVisible = visible
      let controls =
        [attention, attentionButton, metricsLabel]
        + metricButtons
        + [topologyLabel, topology, recentLabel, recentList]
      for control in controls {
        WindowsUIFoundation.show(control, visible)
      }
    }

    static func layout(in bounds: RECT) {
      let padding = Int32(24)
      let gap = Int32(12)
      let left = bounds.left + padding
      let width = min(Int32(960), max(Int32(0), bounds.right - left - padding))
      var top = bounds.top + 8
      _ = MoveWindow(attention, left, top, width - 112, 44, true)
      _ = MoveWindow(attentionButton, left + width - 104, top + 7, 96, 30, true)
      top += 62
      _ = MoveWindow(metricsLabel, left, top, width, 22, true)
      top += 28

      let columns = width >= 880 ? 5 : 3
      let cardWidth = max(Int32(136), (width - gap * Int32(columns - 1)) / Int32(columns))
      let cardHeight = Int32(92)
      for (index, button) in metricButtons.enumerated() {
        let row = Int32(index / columns)
        let column = Int32(index % columns)
        _ = MoveWindow(
          button,
          left + column * (cardWidth + gap),
          top + row * (cardHeight + gap),
          cardWidth,
          cardHeight,
          true
        )
      }
      let metricRows = Int32((metricButtons.count + columns - 1) / columns)
      top += metricRows * cardHeight + max(0, metricRows - 1) * gap + 20
      _ = MoveWindow(topologyLabel, left, top, width, 22, true)
      top += 28
      _ = MoveWindow(topology, left, top, width, 104, true)
      top += 124
      _ = MoveWindow(recentLabel, left, top, width, 22, true)
      top += 28
      _ = MoveWindow(recentList, left, top, width, max(Int32(0), bounds.bottom - top - 20), true)
    }

    private static func metricButton(
      _ parent: HWND?, _ instance: HINSTANCE?, _ id: Int
    ) -> HWND? {
      WindowsUIFoundation.createChild(
        "BUTTON",
        style: DWORD(BS_PUSHBUTTON) | DWORD(BS_MULTILINE),
        parent: parent,
        instance: instance,
        id: id
      )
    }

    private static func sectionLabel(
      _ text: String, parent: HWND?, instance: HINSTANCE?, id: Int
    ) -> HWND? {
      let label = WindowsUIFoundation.createChild(
        "STATIC", text: text, parent: parent, instance: instance, id: id)
      WindowsUIFoundation.applyTitleFont(to: label)
      return label
    }

    private static func connectionLabel(
      _ state: WindowsWorkbenchDisplay.ConnectionState
    ) -> String {
      switch state {
      case .idle: "未连接"
      case .connecting: "正在连接"
      case .connected: "已连接"
      case .unavailable: "不可用"
      }
    }
  }
#endif
