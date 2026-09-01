#if os(Windows)
  import Foundation
  import WinSDK

  extension CodexBridgeWindowsApplication {
    static func applyDisplay(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      chat: WindowsChatWebView
    ) {
      model.refreshDisplaySnapshot()
      management.refreshDisplaySnapshot()
      let display = model.displayBox.current()
      let managementDisplay = management.displayBox.current()
      WindowsMainWindow.updateNavigation(workbench: display, management: managementDisplay)
      WindowsMainWindow.updateOverview(workbench: display, management: managementDisplay)
      applyWorkbench(display)
      applyManagement(managementDisplay)
      applyBrowser(chat)
    }

    private static func applyWorkbench(_ display: WindowsWorkbenchDisplay) {
      guard display != lastAppliedDisplay else { return }
      var lines = [
        "服务连接: \(statusName(display.connectionState))",
        "任务: \(display.taskCount)（运行中 \(display.runningTaskCount)）",
        "审批: \(display.pendingApprovalCount)",
        "MCP 地址: \(display.mcpAddress)",
      ]
      if let detail = display.detailText { lines.append("详情: \(detail)") }
      WindowsMainWindow.setStatusText(lines.joined(separator: "\r\n"))
      let previous = lastAppliedDisplay
      if display.taskRows != previous?.taskRows
        || display.selectedTaskIndex != previous?.selectedTaskIndex
      {
        WindowsMainWindow.setTaskRows(display.taskRows, selectedIndex: display.selectedTaskIndex)
      }
      if display.taskMetadata != previous?.taskMetadata {
        WindowsTaskInspector.setTaskMetadata(display.taskMetadata)
      }
      if display.conversationText != previous?.conversationText {
        WindowsTaskInspector.setConversationText(display.conversationText)
      }
      if display.actionText != previous?.actionText {
        WindowsTaskInspector.setActionStatus(display.actionText)
      }
      if contextChanged(display, from: previous) {
        WindowsTaskInspector.applyContext(display)
      }
      if display.interruptEnabled != previous?.interruptEnabled
        || display.steerEnabled != previous?.steerEnabled
      {
        WindowsTaskInspector.setControls(
          interruptEnabled: display.interruptEnabled,
          steerEnabled: display.steerEnabled
        )
      }
      WindowsApprovalWindow.apply(display)
      lastAppliedDisplay = display
    }

    private static func contextChanged(
      _ display: WindowsWorkbenchDisplay,
      from previous: WindowsWorkbenchDisplay?
    ) -> Bool {
      display.projectRows != previous?.projectRows
        || display.selectedProjectIndex != previous?.selectedProjectIndex
        || display.permissionRows != previous?.permissionRows
        || display.selectedPermissionIndex != previous?.selectedPermissionIndex
        || display.pendingApprovalCount != previous?.pendingApprovalCount
        || display.stopEnabled != previous?.stopEnabled
        || display.deleteEnabled != previous?.deleteEnabled
    }

    private static func applyManagement(_ display: WindowsManagementDisplay) {
      guard display != lastAppliedManagementDisplay else { return }
      WindowsProjectManagementWindow.apply(display.project)
      WindowsAgentManagementWindow.apply(display.agent)
      lastAppliedManagementDisplay = display
    }

    private static func applyBrowser(_ chat: WindowsChatWebView) {
      let placeholder: String?
      switch chat.state {
      case .unsupported:
        placeholder = "内置浏览器不可用：\(chat.errorDetail ?? "未知原因")\r\n可使用上方“在外部浏览器打开”，任务管理功能仍然可用。"
      case .loading:
        placeholder = "正在加载聊天页…"
      case .failed:
        placeholder = "聊天页加载失败：\(chat.errorDetail ?? "未知原因")\r\n可使用上方“在外部浏览器打开”，任务管理功能仍然可用。"
      case .active:
        placeholder = nil
      }
      WindowsBrowserToolbar.setBrowserActionsEnabled(chat.state == .active)
      chat.setVisible(chat.state == .active && WindowsMainWindow.currentPage() == .workbench)
      if placeholder != lastPlaceholderText {
        WindowsMainWindow.setChatPlaceholder(placeholder)
        lastPlaceholderText = placeholder
      }
    }

    static func openChatExternally() {
      "open".withCString(encodedAs: UTF16.self) { operation in
        WindowsChatWebView.chatURL.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(), operation, url, nil, nil, SW_SHOWNORMAL)
        }
      }
    }

    private static func statusName(_ state: WindowsWorkbenchDisplay.ConnectionState) -> String {
      switch state {
      case .idle: "未连接"
      case .connecting: "连接中…"
      case .connected: "已连接"
      case .unavailable: "不可用"
      }
    }
  }
#endif
