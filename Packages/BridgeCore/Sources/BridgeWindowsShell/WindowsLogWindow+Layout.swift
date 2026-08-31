#if os(Windows)
  import WinSDK

  extension WindowsLogWindow {
    static func createControls(parent: HWND, instance: HINSTANCE?) {
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
      let contentHeight = max(Int32(100), height - 58)
      _ = MoveWindow(list, padding, padding, listWidth, contentHeight, true)
      _ = MoveWindow(detail, detailX, padding, detailWidth, contentHeight, true)
      _ = MoveWindow(refreshButton, padding, height - 36, 76, 24, true)
      _ = MoveWindow(status, padding + 88, height - 36, width - padding - 88, 24, true)
    }
  }
#endif
