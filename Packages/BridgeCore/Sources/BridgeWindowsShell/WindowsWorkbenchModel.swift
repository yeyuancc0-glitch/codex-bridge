#if os(Windows)
  import BridgeIPC
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
    public var taskRows: [String]
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
      taskRows: [],
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

    private let client: any BridgeServiceClientProtocol
    private var serviceStatus: IPCServiceStatusResponse?
    private var tasks: [MCPServiceTaskSnapshot] = []

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
        serviceStatus = try await client.status()
        errorMessage = nil
        await refreshTasks()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    public func refreshTasks() async {
      do {
        tasks = try await client.tasks(IPCTaskListRequest())
        errorMessage = nil
        if connectionState != .unavailable { connectionState = .connected }
        publishDisplay()
      } catch {
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    public func shutdown() async {
      await client.close()
    }

    private func fail(_ message: String) {
      errorMessage = message
      connectionState = .unavailable
      publishDisplay()
    }

    private func publishDisplay() {
      let runningCount = tasks.filter { $0.isRunning }.count
      let value = WindowsWorkbenchDisplay(
        connectionState: connectionState,
        mcpAddress: serviceStatus?.localMCPURL ?? "—",
        taskCount: tasks.count,
        runningTaskCount: runningCount,
        taskRows: tasks.map(Self.rowText),
        detailText: errorMessage
      )
      displayBox.store(value)
    }

    private static func rowText(_ task: MCPServiceTaskSnapshot) -> String {
      let state: String
      if task.isRunning {
        state = "运行中"
      } else if task.isTerminal {
        state = "已结束"
      } else {
        state = task.status
      }
      return "\(task.workbenchTitle) — \(state)"
    }
  }
#endif
