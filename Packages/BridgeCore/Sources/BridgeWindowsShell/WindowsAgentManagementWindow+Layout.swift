#if os(Windows)
  import WinSDK

  extension WindowsAgentManagementWindow {
    static func createControls(parent: HWND, instance: HINSTANCE?) {
      providerList = createChild(
        "LISTBOX", "", listStyle, edgeStyle, parent, instance, providerListID)
      providerDetail = createChild(
        "EDIT", "", detailStyle, edgeStyle, parent, instance, providerDetailID)
      installationList = createChild(
        "LISTBOX", "", listStyle, edgeStyle, parent, instance, installationListID)
      installationDetail = createChild(
        "EDIT", "", detailStyle, edgeStyle, parent, instance, installationDetailID)
      executableInput = createChild(
        "EDIT", "", inputStyle, edgeStyle, parent, instance, executableID)
      configurationInput = createChild(
        "EDIT", "", inputStyle, edgeStyle, parent, instance, configurationID)
      configHint = createChild(
        "STATIC", "", DWORD(SS_LEFTNOWORDWRAP), 0, parent, instance, configHintID)
      status = createChild("STATIC", "", DWORD(SS_LEFTNOWORDWRAP), 0, parent, instance, statusID)
      providerLabel = createChild("STATIC", "Provider 目录", 0, 0, parent, instance, providerLabelID)
      installationLabel = createChild(
        "STATIC", "已登记安装", 0, 0, parent, instance, installationLabelID)
      executableLabel = createChild("STATIC", "可执行文件：", 0, 0, parent, instance, executableLabelID)
      configurationLabel = createChild(
        "STATIC", "配置文件：", 0, 0, parent, instance, configurationLabelID)
      registerButton = createChild(
        "BUTTON", "登记并 Probe", DWORD(BS_PUSHBUTTON), 0, parent, instance, registerID)
      enableButton = createChild(
        "BUTTON", "启用", DWORD(BS_PUSHBUTTON), 0, parent, instance, enableID)
      disableButton = createChild(
        "BUTTON", "停用", DWORD(BS_PUSHBUTTON), 0, parent, instance, disableID)
      reprobeButton = createChild(
        "BUTTON", "重新 Probe", DWORD(BS_PUSHBUTTON), 0, parent, instance, reprobeID)
      acceptButton = createChild(
        "BUTTON", "接受替换", DWORD(BS_PUSHBUTTON), 0, parent, instance, acceptID)
      removeButton = createChild(
        "BUTTON", "移除登记", DWORD(BS_PUSHBUTTON), 0, parent, instance, removeID)
      refreshButton = createChild(
        "BUTTON", "刷新", DWORD(BS_PUSHBUTTON), 0, parent, instance, refreshID)
      _ = EnableWindow(registerButton, false)
      _ = EnableWindow(enableButton, false)
      _ = EnableWindow(disableButton, false)
      _ = EnableWindow(reprobeButton, false)
      _ = EnableWindow(acceptButton, false)
      _ = EnableWindow(removeButton, false)
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let leftWidth = Int32(280)
      let rightX = padding + leftWidth + 12
      let rightWidth = max(Int32(100), width - rightX - padding)
      let listTop = Int32(22)
      let listHeight = min(Int32(165), max(Int32(100), height / 4))
      let detailTop = listTop + listHeight + 14
      let detailHeight = min(Int32(148), max(Int32(100), height / 4))
      let formTop = detailTop + detailHeight + 28
      _ = MoveWindow(providerLabel, padding, 2, leftWidth, 18, true)
      _ = MoveWindow(installationLabel, rightX, 2, rightWidth, 18, true)
      _ = MoveWindow(providerList, padding, listTop, leftWidth, listHeight, true)
      _ = MoveWindow(installationList, rightX, listTop, rightWidth, listHeight, true)
      _ = MoveWindow(providerDetail, padding, detailTop, leftWidth, detailHeight, true)
      _ = MoveWindow(installationDetail, rightX, detailTop, rightWidth, detailHeight, true)
      _ = MoveWindow(executableLabel, padding, formTop + 3, 96, 20, true)
      _ = MoveWindow(executableInput, 110, formTop, width - 122, 24, true)
      _ = MoveWindow(configurationLabel, padding, formTop + 37, 96, 20, true)
      _ = MoveWindow(configurationInput, 110, formTop + 34, width - 122, 24, true)
      _ = MoveWindow(configHint, 110, formTop + 58, width - 122, 20, true)
      _ = MoveWindow(registerButton, padding, formTop + 86, 108, 24, true)
      _ = MoveWindow(enableButton, padding + 118, formTop + 86, 68, 24, true)
      _ = MoveWindow(disableButton, padding + 194, formTop + 86, 68, 24, true)
      _ = MoveWindow(reprobeButton, padding + 270, formTop + 86, 96, 24, true)
      _ = MoveWindow(acceptButton, padding + 376, formTop + 86, 88, 24, true)
      _ = MoveWindow(removeButton, padding + 474, formTop + 86, 88, 24, true)
      _ = MoveWindow(refreshButton, padding + 572, formTop + 86, 68, 24, true)
      _ = MoveWindow(status, padding, formTop + 120, width - padding * 2, 40, true)
    }
  }
#endif
