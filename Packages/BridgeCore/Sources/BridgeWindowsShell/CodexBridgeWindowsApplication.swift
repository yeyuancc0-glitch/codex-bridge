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
    static var lastAppliedDisplay: WindowsWorkbenchDisplay?
    static var lastAppliedManagementDisplay: WindowsManagementDisplay?
    static var lastPlaceholderText: String? = ""

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
      case .selectProjectsSection(let index):
        WindowsEmbeddedPages.selectSection(page: .projects, index: index)
        if index == 0 {
          Task { await management.refreshProjects() }
        } else {
          auxiliary.run(.refreshWorkspace)
        }
      case .selectConnectionsSection(let index):
        WindowsEmbeddedPages.selectSection(page: .connections, index: index)
        if index == 0 {
          auxiliary.run(.refreshMCPConnections)
        } else {
          Task { await management.refreshAgents() }
        }
      case .selectSettingsSection(let index):
        WindowsEmbeddedPages.selectSection(page: .settings, index: index)
        if index == 0 {
          auxiliary.run(.refreshSettings)
        } else {
          auxiliary.run(.refreshAgentDefaults)
        }
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
        management.selectProject(at: index)
        auxiliary.run(.selectWorkspaceProject(index: index))
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
        WindowsEmbeddedPages.selectSection(page: .projects, index: 0)
        Task { await management.refreshProjects() }
      case .showAgents:
        WindowsMainWindow.selectPage(.connections)
        WindowsEmbeddedPages.selectSection(page: .connections, index: 1)
        Task { await management.refreshAgents() }
      case .showWorkspace:
        WindowsMainWindow.selectPage(.projects)
        WindowsEmbeddedPages.selectSection(page: .projects, index: 1)
        auxiliary.run(.refreshWorkspace)
      case .showAgentDefaults:
        WindowsMainWindow.selectPage(.settings)
        WindowsEmbeddedPages.selectSection(page: .settings, index: 1)
        auxiliary.run(.refreshAgentDefaults)
      case .showLogs:
        WindowsMainWindow.selectPage(.logs)
        auxiliary.run(.refreshLogs)
      case .showSettings:
        WindowsMainWindow.selectPage(.settings)
        WindowsEmbeddedPages.selectSection(page: .settings, index: 0)
        auxiliary.run(.refreshSettings)
      case .selectProject(let index):
        management.selectProject(at: index)
        auxiliary.run(.selectWorkspaceProject(index: index))
        Task { await model.selectWorkbenchProject(at: index) }
      case .selectWorkspaceProject(let index):
        auxiliary.run(.selectWorkspaceProject(index: index))
        management.selectProject(at: index)
        Task { await model.selectWorkbenchProject(at: index) }
      case .refreshProjects:
        Task { await management.refreshProjects() }
      case .registerProject(let name, let path):
        Task {
          await management.registerProject(name: name, path: path)
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
      case .removeSelectedProject:
        Task {
          await management.removeSelectedProject()
          await model.connectAndRefresh()
          auxiliary.run(.refreshWorkspace)
        }
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
        auxiliary.run(.refreshWorkspace)
      case .logs:
        auxiliary.run(.refreshLogs)
      case .connections:
        auxiliary.run(.refreshMCPConnections)
        Task { await management.refreshAgents() }
      case .settings:
        auxiliary.run(.refreshSettings)
        auxiliary.run(.refreshAgentDefaults)
      }
    }

  }
#endif
