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

    public static func main() async {
      let model = WindowsWorkbenchModel()
      let management = WindowsManagementModel(client: model.client)
      let auxiliary = WindowsAuxiliaryRuntime(client: model.client)
      let chat = WindowsChatWebView()
      guard let window = WindowsMainWindow.create() else { return }
      WindowsMainWindow.chat = chat
      chat.attach(to: window)

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
      case .refreshTasks:
        Task { await model.refreshSelectedTask() }
      case .startService:
        Task {
          await model.startServiceAndConnect()
          await management.refresh()
        }
      case .selectTask(let index):
        model.selectTask(at: index)
      case .interruptSelectedTask:
        Task { await model.interruptSelectedTask() }
      case .submitSteer(let input):
        Task {
          if await model.submitSteer(input: input) {
            WindowsTaskInspector.clearSteerInput()
          }
        }
      case .showApprovals:
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
        WindowsProjectManagementWindow.show(owner: WindowsMainWindow.currentWindow())
        management.refreshDisplaySnapshot()
        WindowsProjectManagementWindow.apply(management.displayBox.current().project)
        Task { await management.refresh() }
      case .showAgents:
        WindowsAgentManagementWindow.show(owner: WindowsMainWindow.currentWindow())
        management.refreshDisplaySnapshot()
        WindowsAgentManagementWindow.apply(management.displayBox.current().agent)
        Task { await management.refresh() }
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

    private static func applyDisplay(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      chat: WindowsChatWebView
    ) {
      model.refreshDisplaySnapshot()
      management.refreshDisplaySnapshot()
      let display = model.displayBox.current()
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

      let managementDisplay = management.displayBox.current()
      if managementDisplay != lastAppliedManagementDisplay {
        WindowsProjectManagementWindow.apply(managementDisplay.project)
        WindowsAgentManagementWindow.apply(managementDisplay.agent)
        lastAppliedManagementDisplay = managementDisplay
      }

      let placeholder: String?
      switch chat.state {
      case .unsupported:
        placeholder = "未检测到 WebView2 Runtime，聊天页不可用；任务管理功能不受影响。"
      case .loading:
        placeholder = "正在加载聊天页…"
      case .failed:
        placeholder = "聊天页加载失败，已停用；任务管理功能不受影响。"
      case .active:
        placeholder = nil
      }
      if placeholder != lastPlaceholderText {
        WindowsMainWindow.setChatPlaceholder(placeholder)
        lastPlaceholderText = placeholder
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
