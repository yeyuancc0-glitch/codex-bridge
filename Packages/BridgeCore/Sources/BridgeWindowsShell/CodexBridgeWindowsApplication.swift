#if os(Windows)
  import Foundation
  import WinSDK

  /// Windows desktop shell entry point. The Win32 message loop runs inside the
  /// main-actor task; `await Task.yield()` between messages is what lets
  /// main-actor jobs (service calls, model updates) execute on Windows, where
  /// nothing else drains the main executor while GetMessageW blocks. The
  /// 250ms window timer guarantees the loop wakes up regularly.
  @MainActor
  public enum CodexBridgeWindowsApplication {
    private static var lastAppliedDisplay: WindowsWorkbenchDisplay?
    private static var lastAppliedManagementDisplay: WindowsManagementDisplay?
    private static var lastPlaceholderText: String? = ""

    public static func main(comInitialization: HRESULT, comThreadID: DWORD) async {
      let isCOMThread = GetCurrentThreadId() == comThreadID
      defer {
        if comInitialization >= 0 && isCOMThread {
          CoUninitialize()
        }
      }
      let model = WindowsWorkbenchModel()
      let management = WindowsManagementModel(client: model.client)
      let auxiliary = WindowsAuxiliaryRuntime(client: model.client)
      let chat = WindowsChatWebView(
        comInitialization: comInitialization,
        threadMatches: isCOMThread
      )
      guard let window = WindowsMainWindow.create() else { return }
      WindowsMainWindow.chat = chat
      chat.attach(to: window)
      chat.setVisible(false)

      // Startup path per platform contract: launch the service when the pipe
      // is not connectable, then connect and load tasks.
      Task {
        await model.startServiceAndConnect()
        await management.refresh()
      }

      var message = MSG()
      while GetMessageW(&message, nil, 0, 0) {
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
        for command in WindowsMainWindow.takePendingCommands() {
          run(command, model: model, management: management, auxiliary: auxiliary)
        }
        await Task.yield()
        applyDisplay(model: model, management: management, chat: chat)
        auxiliary.applyDisplay()
      }
      chat.shutdown()
      auxiliary.shutdown()
      WindowsApprovalWindow.shutdown()
      WindowsProjectManagementWindow.shutdown()
      WindowsAgentManagementWindow.shutdown()
      await model.shutdown()
    }

    private static func run(
      _ command: MainWindowCommand,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      switch command {
      case .selectPage(let index):
        guard let page = WindowsMainPage(rawValue: index) else { return }
        WindowsMainWindow.selectPage(page)
        refresh(page: page, model: model, management: management, auxiliary: auxiliary)
      case .refreshCurrentPage:
        refresh(
          page: WindowsMainWindow.currentPage(),
          model: model,
          management: management,
          auxiliary: auxiliary
        )
      case .openRecentTask(let index):
        model.selectTask(at: index)
        WindowsMainWindow.selectPage(.workbench)
      case .browserBack:
        WindowsMainWindow.chat?.goBack()
      case .browserForward:
        WindowsMainWindow.chat?.goForward()
      case .browserReload:
        WindowsMainWindow.chat?.reload()
      case .openChatExternally:
        openChatExternally()
      case .refreshTasks:
        Task { await model.refreshSelectedTask() }
      case .startService:
        Task {
          await model.startServiceAndConnect()
          await management.refresh()
        }
      case .selectTask(let index):
        model.selectTask(at: index)
      case .selectWorkbenchProject(let index):
        Task { await model.selectWorkbenchProject(at: index) }
      case .selectWorkbenchPermission(let index):
        Task { await model.selectWorkbenchPermission(at: index) }
      case .selectWorkbenchItem(let index):
        Task { await model.selectWorkbenchItem(at: index) }
      case .interruptSelectedTask:
        Task { await model.interruptSelectedTask() }
      case .stopSelectedTask:
        Task { await model.stopSelectedTask() }
      case .deleteSelectedTask:
        Task { await model.deleteSelectedTask() }
      case .submitSteer(let input):
        Task {
          if await model.submitSteer(input: input) {
            WindowsTaskInspector.clearSteerInput()
          }
        }
      case .showApprovals:
        WindowsMainWindow.selectPage(.workbench)
        WindowsApprovalWindow.show(owner: WindowsMainWindow.currentWindow())
        model.refreshDisplaySnapshot()
        WindowsApprovalWindow.apply(model.displayBox.current())
        Task { await model.refreshApprovals() }
      case .selectApproval(let index):
        model.selectApproval(at: index)
      case .refreshApprovals:
        Task { await model.refreshApprovals() }
      case .resolveApproval(let decision):
        Task { await model.resolveSelectedApproval(decision: decision) }
      case .showProjects:
        WindowsMainWindow.selectPage(.projects)
        Task { await management.refreshProjects() }
      case .showAgents:
        WindowsMainWindow.selectPage(.connections)
        Task { await management.refreshAgents() }
      case .selectProject(let index):
        management.selectProject(at: index)
      case .refreshProjects:
        Task { await management.refreshProjects() }
      case .registerProject(let name, let path):
        Task { await management.registerProject(name: name, path: path) }
      case .removeSelectedProject:
        Task { await management.removeSelectedProject() }
      case .saveProjectPolicy(let read, let write, let network):
        Task {
          await management.saveSelectedProjectPolicy(
            read: read,
            write: write,
            network: network
          )
        }
      case .selectAgentProvider(let index):
        management.selectProvider(at: index)
      case .selectAgentInstallation(let index):
        management.selectInstallation(at: index)
      case .refreshAgents:
        Task { await management.refreshAgents() }
      case .registerAgent(let providerID, let executablePath, let configurationPath):
        Task {
          await management.registerAgent(
            providerID: providerID,
            executablePath: executablePath,
            configurationPath: configurationPath
          )
        }
      case .enableSelectedAgent:
        Task { await management.setSelectedAgentEnabled(true) }
      case .disableSelectedAgent:
        Task { await management.setSelectedAgentEnabled(false) }
      case .reprobeSelectedAgent(let acceptReplacement):
        Task { await management.reprobeSelectedAgent(acceptReplacement: acceptReplacement) }
      case .removeSelectedAgent:
        Task { await management.removeSelectedAgent() }
      default:
        auxiliary.run(command)
      }
    }

    private static func refresh(
      page: WindowsMainPage,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) {
      switch page {
      case .overview:
        Task {
          await model.refreshTasks()
          await management.refresh()
        }
      case .workbench:
        Task { await model.refreshSelectedTask() }
      case .projects:
        Task { await management.refreshProjects() }
      case .logs:
        auxiliary.run(.refreshLogs)
      case .connections:
        Task { await management.refreshAgents() }
      case .settings:
        auxiliary.run(.refreshSettings)
      }
    }

    private static func applyDisplay(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      chat: WindowsChatWebView
    ) {
      model.refreshDisplaySnapshot()
      management.refreshDisplaySnapshot()
      let display = model.displayBox.current()
      let managementDisplay = management.displayBox.current()
      WindowsMainWindow.updateNavigation(
        workbench: display,
        management: managementDisplay
      )
      WindowsMainWindow.updateOverview(
        workbench: display,
        management: managementDisplay
      )
      if display != lastAppliedDisplay {
        var lines = [
          "服务连接: \(statusName(display.connectionState))",
          "任务: \(display.taskCount)（运行中 \(display.runningTaskCount)）",
          "审批: \(display.pendingApprovalCount)",
          "MCP 地址: \(display.mcpAddress)",
        ]
        if let detail = display.detailText {
          lines.append("详情: \(detail)")
        }
        WindowsMainWindow.setStatusText(lines.joined(separator: "\r\n"))
        let previous = lastAppliedDisplay
        if display.taskRows != previous?.taskRows
          || display.selectedTaskIndex != previous?.selectedTaskIndex
        {
          WindowsMainWindow.setTaskRows(
            display.taskRows,
            selectedIndex: display.selectedTaskIndex
          )
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
        if display.projectRows != previous?.projectRows
          || display.selectedProjectIndex != previous?.selectedProjectIndex
          || display.permissionRows != previous?.permissionRows
          || display.selectedPermissionIndex != previous?.selectedPermissionIndex
          || display.pendingApprovalCount != previous?.pendingApprovalCount
          || display.stopEnabled != previous?.stopEnabled
          || display.deleteEnabled != previous?.deleteEnabled
        {
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

      if managementDisplay != lastAppliedManagementDisplay {
        WindowsProjectManagementWindow.apply(managementDisplay.project)
        WindowsAgentManagementWindow.apply(managementDisplay.agent)
        lastAppliedManagementDisplay = managementDisplay
      }

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

    private static func openChatExternally() {
      "open".withCString(encodedAs: UTF16.self) { operation in
        WindowsChatWebView.chatURL.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(),
            operation,
            url,
            nil,
            nil,
            SW_SHOWNORMAL
          )
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
