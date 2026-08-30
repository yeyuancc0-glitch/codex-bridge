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
    private static var lastPlaceholderText: String? = ""

    public static func main() async {
      let model = WindowsWorkbenchModel()
      let chat = WindowsChatWebView()
      guard let window = WindowsMainWindow.create() else { return }
      WindowsMainWindow.chat = chat
      chat.attach(to: window)

      // Startup path per platform contract: launch the service when the pipe
      // is not connectable, then connect and load tasks.
      Task { await model.startServiceAndConnect() }

      var message = MSG()
      while GetMessageW(&message, nil, 0, 0) {
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
        for command in WindowsMainWindow.takePendingCommands() {
          run(command, model: model)
        }
        await Task.yield()
        applyDisplay(model: model, chat: chat)
      }
      chat.shutdown()
      await model.shutdown()
    }

    private static func run(_ command: MainWindowCommand, model: WindowsWorkbenchModel) {
      switch command {
      case .refreshTasks:
        Task { await model.refreshSelectedTask() }
      case .startService:
        Task { await model.startServiceAndConnect() }
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
      }
    }

    private static func applyDisplay(model: WindowsWorkbenchModel, chat: WindowsChatWebView) {
      model.refreshDisplaySnapshot()
      let display = model.displayBox.current()
      if display != lastAppliedDisplay {
        var lines = [
          "服务连接: \(statusName(display.connectionState))",
          "任务: \(display.taskCount)（运行中 \(display.runningTaskCount)）",
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
        lastAppliedDisplay = display
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
