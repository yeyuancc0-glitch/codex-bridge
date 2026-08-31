#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  @MainActor
  final class WindowsLogModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsLogDisplay>

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var items: [TaskLogPresentation.Item] = []
    var selectedItemID: String?
    private var busy = false
    private var statusText = "尚未加载任务日志。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      displayBox = AuxiliaryDisplayBox(
        value: WindowsLogDisplay(
          connectionState: .idle,
          rows: [],
          selectedIndex: nil,
          detailText: "暂无任务事件。",
          refreshEnabled: false,
          statusText: statusText
        )
      )
    }

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取任务日志…"
      publishDisplay()
      defer { busy = false }
      do {
        _ = try await client.status()
        connectionState = .connected
        let projects = (try? await client.projects()) ?? []
        let tasks = try await client.tasks(IPCTaskListRequest(limit: 200))
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.projectID, $0.name) })
        items = TaskLogPresentation.flatten(tasks: tasks, projectNames: names)
        reconcileSelection()
        statusText = "已加载 \(items.count) 条任务事件。"
      } catch {
        statusText = "任务日志读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func selectItem(at index: Int) {
      guard items.indices.contains(index) else { return }
      selectedItemID = items[index].id
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func reconcileSelection() {
      if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) { return }
      selectedItemID = items.first?.id
    }

    private func publishDisplay() {
      let selectedIndex = selectedItemID.flatMap { id in items.firstIndex { $0.id == id } }
      let selected = selectedIndex.flatMap { items[$0] }
      let value = WindowsLogDisplay(
        connectionState: connectionState,
        rows: items.map(\.rowText),
        selectedIndex: selectedIndex,
        detailText: selected?.detailText ?? "暂无任务事件。",
        refreshEnabled: connectionState == .connected && !busy,
        statusText: statusText
      )
      displayBox.store(value)
    }
  }
#endif
