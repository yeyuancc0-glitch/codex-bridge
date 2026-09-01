#if os(Windows)
  import WinSDK

  extension WindowsLogWindow {
    static func createControls(parent: HWND, instance: HINSTANCE?) {
      searchInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT", style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: searchID)
      projectFilter = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX", style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent, instance: instance, id: projectFilterID)
      kindFilter = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX", style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent, instance: instance, id: kindFilterID)
      list = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: listID
      )
      detail = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: detailID
      )
      refreshButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "刷新", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: refreshID
      )
      copyButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "复制日志", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: copyID)
      status = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", parent: parent, instance: instance, id: statusID
      )
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let listWidth = min(Int32(380), max(Int32(240), width / 2))
      let detailX = padding + listWidth + 10
      let detailWidth = max(Int32(160), width - detailX - padding)
      let toolbarHeight = Int32(32)
      let contentTop = padding + toolbarHeight
      let contentHeight = max(Int32(100), height - contentTop - 46)
      _ = MoveWindow(searchInput, padding, padding, 240, 24, true)
      _ = MoveWindow(projectFilter, padding + 250, padding, 160, 180, true)
      _ = MoveWindow(kindFilter, padding + 420, padding, 120, 180, true)
      _ = MoveWindow(copyButton, padding + 550, padding, 84, 24, true)
      _ = MoveWindow(list, padding, contentTop, listWidth, contentHeight, true)
      _ = MoveWindow(detail, detailX, contentTop, detailWidth, contentHeight, true)
      _ = MoveWindow(refreshButton, padding, height - 36, 76, 24, true)
      _ = MoveWindow(status, padding + 88, height - 36, width - padding - 88, 24, true)
    }
  }
#endif
