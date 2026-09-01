#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  /// Value snapshot the Win32 message-loop thread renders. Updated only by the
  /// model on the main actor; consumed through `WorkbenchDisplayBox`.
  public struct WindowsWorkbenchDisplay: Equatable, Sendable {
    public enum ConnectionState: Equatable, Sendable {
      case idle
      case connecting
      case connected
      case unavailable
    }

    public var connectionState: ConnectionState
    public var mcpAddress: String
    public var taskCount: Int
    public var runningTaskCount: Int
    public var pendingApprovalCount: Int
    public var projectRows: [String]
    public var selectedProjectIndex: Int?
    public var permissionRows: [String]
    public var selectedPermissionIndex: Int?
    public var taskRows: [String]
    public var recentTaskRows: [String]
    public var selectedTaskID: String?
    public var selectedTaskIndex: Int?
    public var taskMetadata: String
    public var conversationText: String
    public var interruptEnabled: Bool
    public var stopEnabled: Bool
    public var deleteEnabled: Bool
    public var steerEnabled: Bool
    public var actionText: String?
    public var approvalRows: [String]
    public var selectedApprovalIndex: Int?
    public var approvalDetailText: String
    public var approvalAllowDecisions: [String]
    public var approvalAllowEnabled: Bool
    public var approvalDenyEnabled: Bool
    public var approvalStatusText: String?
    public var detailText: String?
  }

  /// Lock-guarded bridge between main-actor model updates and the
  /// non-isolated Win32 render loop (single reader, same-thread comparisons).
  public final class WorkbenchDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = WindowsWorkbenchDisplay(
      connectionState: .idle,
      mcpAddress: "—",
      taskCount: 0,
      runningTaskCount: 0,
      pendingApprovalCount: 0,
      projectRows: [],
      selectedProjectIndex: nil,
      permissionRows: ["只读", "可写"],
      selectedPermissionIndex: 1,
      taskRows: [],
      recentTaskRows: [],
      selectedTaskID: nil,
      selectedTaskIndex: nil,
      taskMetadata: "未选择任务",
      conversationText: "请从上方选择任务。",
      interruptEnabled: false,
      stopEnabled: false,
      deleteEnabled: false,
      steerEnabled: false,
      actionText: nil,
      approvalRows: [],
      selectedApprovalIndex: nil,
      approvalDetailText: "暂无待处理审批。",
      approvalAllowDecisions: [],
      approvalAllowEnabled: false,
      approvalDenyEnabled: false,
      approvalStatusText: nil,
      detailText: nil
    )

    public func current() -> WindowsWorkbenchDisplay {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func store(_ newValue: WindowsWorkbenchDisplay) {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }

  /// Windows shell runtime over the cross-platform service client. All
  /// mutations happen on the main actor; the Win32 loop only reads the
  /// display box. (ObservableObject is unavailable on the Windows toolchain,
  /// so the shell subscribes via the box instead of Combine.)
  @MainActor
  public final class WindowsWorkbenchModel {
    public private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    public private(set) var errorMessage: String?
    public let displayBox = WorkbenchDisplayBox()

    let client: any BridgeServiceClientProtocol
    var serviceStatus: IPCServiceStatusResponse?
    var projects: [MCPProjectSummary] = []
    var agentProviders: [IPCAgentProviderSummary] = []
    var tasks: [MCPServiceTaskSnapshot] = []
    var threads: [MCPThreadSummary] = []
    var selectedProjectID: String?
    var selectedThreadID: String?
    var selectedThreadPage: MCPThreadReadPage?
    var workbenchPermissionMode = "workspace-write"
    var selectedTaskID: String?
    var conversation: TaskConversationModel?
    var conversationWasTerminal = false
    var actionText: String?
    var approvals: [IPCApprovalSummary] = []
    var directApprovals: [IPCPendingDirectApproval] = []
    var selectedApprovalID: ApprovalPresentation.Identifier?
    var approvalSelectionGeneration: UInt64 = 0
    var resolvingApprovalIDs: Set<ApprovalPresentation.Identifier> = []
    var approvalStatusText: String?
    var approvalRefreshInProgress = false

    public init() {
      client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      publishDisplay()
    }

    /// Launches the service if needed, then verifies connectivity via
    /// `status()` and pulls the task list.
    public func startServiceAndConnect() async {
      connectionState = .connecting
      publishDisplay()
      let launched = await Task.detached(priority: .utility) {
        WindowsServiceLauncher.ensureServiceRunning()
      }.value
      guard launched else {
        fail("未能连接后台服务：codex-bridge-service.exe 启动失败或管道未就绪。")
        return
      }
      await connectAndRefresh()
    }

    /// Verifies the pipe transport with a `status()` round trip, then loads tasks.
    public func connectAndRefresh() async {
      connectionState = .connecting
      publishDisplay()
      do {
        let status = try await client.status()
        serviceStatus = status
        projects = (try? await client.projects()) ?? projects
        agentProviders = (try? await client.agentCatalog())?.providers ?? []
        selectedProjectID =
          projects.first(where: { $0.projectID == status.workbenchProjectID })?.projectID
          ?? selectedProjectID
          ?? projects.first?.projectID
        workbenchPermissionMode =
          Self.permissionModes.contains(status.workbenchPermissionMode ?? "")
          ? status.workbenchPermissionMode!
          : workbenchPermissionMode
        errorMessage = nil
        await refreshTasks()
        await loadThreads()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    public func refreshTasks() async {
      await loadTasks()
      guard connectionState == .connected else { return }
      await refreshApprovals()
    }

    public func shutdown() async {
      conversation?.cancel()
      await client.close()
    }

    func refreshDisplaySnapshot() {
      publishDisplay()
    }

    private func fail(_ message: String) {
      errorMessage = message
      connectionState = .unavailable
      publishDisplay()
    }

    func loadTasks() async {
      do {
        tasks = try await client.tasks(IPCTaskListRequest())
        errorMessage = nil
        connectionState = .connected
        reconcileSelectedTask()
        selectDefaultTaskIfNeeded()
        publishDisplay()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    func reconcileSelectedTask() {
      guard let selectedTaskID else { return }
      guard
        let task = tasks.first(where: {
          $0.taskID == selectedTaskID
            && (selectedProjectID == nil || $0.projectID == selectedProjectID)
        })
      else {
        self.selectedTaskID = nil
        conversation?.cancel()
        conversation = nil
        conversationWasTerminal = false
        actionText = nil
        return
      }
      if conversation?.taskID != task.taskID || conversationWasTerminal != task.isTerminal {
        openConversation(for: task)
      }
      conversationWasTerminal = task.isTerminal
    }

    func openConversation(for task: MCPServiceTaskSnapshot) {
      conversation?.cancel()
      let next = TaskConversationModel(
        taskID: task.taskID,
        client: client,
        isTerminal: task.isTerminal
      )
      conversation = next
      conversationWasTerminal = task.isTerminal
      Task { [weak self, weak next] in
        await next?.start()
        guard let self, self.conversation === next else { return }
        self.publishDisplay()
      }
    }

    var selectedTask: MCPServiceTaskSnapshot? {
      guard let selectedTaskID else { return nil }
      return tasks.first(where: { $0.taskID == selectedTaskID })
    }
  }
#endif
