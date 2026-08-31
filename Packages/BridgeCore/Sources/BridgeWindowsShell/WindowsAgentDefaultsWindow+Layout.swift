#if os(Windows)
  import WinSDK

  extension WindowsAgentDefaultsWindow {
    nonisolated(unsafe) static var providerLabel: HWND?
    nonisolated(unsafe) static var installationLabel: HWND?
    nonisolated(unsafe) static var modelLabel: HWND?
    nonisolated(unsafe) static var effortLabel: HWND?
    nonisolated(unsafe) static var permissionLabelControl: HWND?
    nonisolated(unsafe) static var refreshModelsButton: HWND?
    nonisolated(unsafe) static var saveButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?

    static func createControls(parent: HWND, instance: HINSTANCE?) {
      createLists(parent: parent, instance: instance)
      createForm(parent: parent, instance: instance)
      createActions(parent: parent, instance: instance)
    }

    private static func createLists(parent: HWND, instance: HINSTANCE?) {
      providerLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "Provider", parent: parent, instance: instance, id: 6501)
      installationLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "安装记录", parent: parent, instance: instance, id: 6502)
      providerList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: providerListID
      )
      installationList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: installationListID
      )
      detail = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: detailID
      )
    }

    private static func createForm(parent: HWND, instance: HINSTANCE?) {
      modelLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "默认模型", parent: parent, instance: instance, id: 6503)
      modelCombo = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: modelID
      )
      effortLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "推理强度", parent: parent, instance: instance, id: 6504)
      effortCombo = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: effortID
      )
      permissionLabelControl = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "权限模式", parent: parent, instance: instance, id: 6505)
      permissionCombo = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: permissionID
      )
    }

    private static func createActions(parent: HWND, instance: HINSTANCE?) {
      refreshModelsButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "重探测模型", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: refreshModelsID
      )
      saveButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "保存默认值", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: saveID
      )
      refreshButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "刷新目录", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: refreshID
      )
      status = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", parent: parent, instance: instance, id: statusID
      )
      _ = EnableWindow(refreshModelsButton, false)
      _ = EnableWindow(saveButton, false)
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let gap = Int32(10)
      let column = max(Int32(160), (width - padding * 2 - gap) / 2)
      let rightX = padding + column + gap
      let listTop = Int32(24)
      let listHeight = min(Int32(200), max(Int32(150), height / 3))
      let detailTop = listTop + listHeight + 14
      let detailHeight = min(Int32(150), max(Int32(100), height / 4))
      let formTop = detailTop + detailHeight + 28
      let labelWidth = Int32(72)
      let inputX = padding + labelWidth
      let inputWidth = max(Int32(140), width - inputX - padding)
      _ = MoveWindow(providerLabel, padding, 3, column, 20, true)
      _ = MoveWindow(installationLabel, rightX, 3, column, 20, true)
      _ = MoveWindow(providerList, padding, listTop, column, listHeight, true)
      _ = MoveWindow(installationList, rightX, listTop, column, listHeight, true)
      _ = MoveWindow(detail, padding, detailTop, width - padding * 2, detailHeight, true)
      _ = MoveWindow(modelLabel, padding, formTop + 3, labelWidth, 20, true)
      _ = MoveWindow(modelCombo, inputX, formTop, inputWidth, 160, true)
      _ = MoveWindow(effortLabel, padding, formTop + 37, labelWidth, 20, true)
      _ = MoveWindow(effortCombo, inputX, formTop + 34, inputWidth, 160, true)
      _ = MoveWindow(permissionLabelControl, padding, formTop + 71, labelWidth, 20, true)
      _ = MoveWindow(permissionCombo, inputX, formTop + 68, inputWidth, 160, true)
      let buttonTop = formTop + 106
      _ = MoveWindow(refreshModelsButton, padding, buttonTop, 110, 24, true)
      _ = MoveWindow(saveButton, padding + 120, buttonTop, 100, 24, true)
      _ = MoveWindow(refreshButton, padding + 230, buttonTop, 100, 24, true)
      _ = MoveWindow(status, padding, buttonTop + 34, width - padding * 2, 38, true)
    }
  }
#endif
