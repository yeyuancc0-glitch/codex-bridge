#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsLogModel {
    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsLogDisplay>

    private(set) var connectionState: WindowsWorkbenchDisplay.ConnectionState = .idle
    private(set) var items: [TaskLogPresentation.Item] = []
    private(set) var projectNames: [String] = []
    var searchText = ""
    var selectedProjectIndex = 0
    var selectedKindIndex = 0
    var selectedItemID: String?
    private var busy = false
    private var statusText = "尚未加载任务日志。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      displayBox = AuxiliaryDisplayBox(
        value: WindowsLogDisplay(
          connectionState: .idle,
          searchText: "",
          projectRows: ["全部项目"],
          selectedProjectIndex: 0,
          kindRows: Self.kindRows,
          selectedKindIndex: 0,
          rows: [],
          selectedIndex: nil,
          detailText: "暂无任务事件。",
          refreshEnabled: false,
          copyEnabled: false,
          copyText: "",
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
        projectNames = projects.map(\.name).sorted()
        selectedProjectIndex = min(selectedProjectIndex, projectNames.count)
        items = TaskLogPresentation.flatten(tasks: tasks, projectNames: names)
        reconcileSelection()
        statusText = "已加载 \(items.count) 条任务事件。"
      } catch {
        statusText = "任务日志读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func selectItem(at index: Int) {
      let filtered = filteredItems
      guard filtered.indices.contains(index) else { return }
      selectedItemID = filtered[index].id
      publishDisplay()
    }

    func setSearchText(_ text: String) {
      guard searchText != text else { return }
      searchText = text
      reconcileSelection()
      publishDisplay()
    }

    func setProjectFilter(_ index: Int) {
      guard (0...projectNames.count).contains(index), selectedProjectIndex != index else { return }
      selectedProjectIndex = index
      reconcileSelection()
      publishDisplay()
    }

    func setKindFilter(_ index: Int) {
      guard Self.kindRows.indices.contains(index), selectedKindIndex != index else { return }
      selectedKindIndex = index
      reconcileSelection()
      publishDisplay()
    }

    func didCopy(_ success: Bool) {
      statusText = success ? "已复制 \(filteredItems.count) 条日志记录。" : "复制日志失败。"
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func reconcileSelection() {
      let filtered = filteredItems
      if let selectedItemID, filtered.contains(where: { $0.id == selectedItemID }) { return }
      selectedItemID = filtered.first?.id
    }

    private func publishDisplay() {
      let filtered = filteredItems
      let selectedIndex = selectedItemID.flatMap { id in filtered.firstIndex { $0.id == id } }
      let selected = selectedIndex.flatMap { filtered[$0] }
      let value = WindowsLogDisplay(
        connectionState: connectionState,
        searchText: searchText,
        projectRows: ["全部项目"] + projectNames,
        selectedProjectIndex: selectedProjectIndex,
        kindRows: Self.kindRows,
        selectedKindIndex: selectedKindIndex,
        rows: filtered.map(\.rowText),
        selectedIndex: selectedIndex,
        detailText: selected?.detailText ?? "暂无任务事件。",
        refreshEnabled: connectionState == .connected && !busy,
        copyEnabled: !filtered.isEmpty,
        copyText: filtered.map(\.rowText).joined(separator: "\r\n"),
        statusText: "\(statusText) 当前显示 \(filtered.count) 条。"
      )
      displayBox.store(value)
    }

    private var filteredItems: [TaskLogPresentation.Item] {
      let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let project =
        selectedProjectIndex > 0 && projectNames.indices.contains(selectedProjectIndex - 1)
        ? projectNames[selectedProjectIndex - 1]
        : nil
      let kind =
        Self.kindRows.indices.contains(selectedKindIndex) && selectedKindIndex > 0
        ? Self.kindRows[selectedKindIndex]
        : nil
      return items.filter { item in
        if let project, !item.rowText.contains("· \(project) ·") { return false }
        if let kind, !item.rowText.contains("· \(kind) ·") { return false }
        if !query.isEmpty {
          return item.rowText.lowercased().contains(query)
            || item.detailText.lowercased().contains(query)
        }
        return true
      }
    }

    private static let kindRows = ["全部类型", "命令", "文件", "错误", "事件"]
  }
#endif
