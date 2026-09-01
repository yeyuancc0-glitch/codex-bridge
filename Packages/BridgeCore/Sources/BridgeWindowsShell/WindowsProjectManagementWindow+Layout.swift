#if os(Windows)
  import WinSDK

  extension WindowsProjectManagementWindow {
    static func createControls(parent: HWND, instance: HINSTANCE?) {
      listBox = createChild("LISTBOX", "", listStyle, edgeStyle, parent, instance, listID)
      detail = createChild("EDIT", "", detailStyle, edgeStyle, parent, instance, detailID)
      status = createChild("STATIC", "", DWORD(SS_LEFT), 0, parent, instance, statusID)
      nameInput = createChild("EDIT", "", inputStyle, edgeStyle, parent, instance, nameID)
      pathInput = createChild("EDIT", "", inputStyle, edgeStyle, parent, instance, pathID)
      readCombo = createChild("COMBOBOX", "", comboStyle, 0, parent, instance, readID)
      writeCombo = createChild("COMBOBOX", "", comboStyle, 0, parent, instance, writeID)
      networkCombo = createChild("COMBOBOX", "", comboStyle, 0, parent, instance, networkID)
      nameLabel = createChild("STATIC", "项目名：", 0, 0, parent, instance, nameLabelID)
      pathLabel = createChild("STATIC", "绝对路径：", 0, 0, parent, instance, pathLabelID)
      readLabel = createChild("STATIC", "读取：", 0, 0, parent, instance, readLabelID)
      writeLabel = createChild("STATIC", "写入：", 0, 0, parent, instance, writeLabelID)
      networkLabel = createChild("STATIC", "网络：", 0, 0, parent, instance, networkLabelID)
      registerButton = createChild(
        "BUTTON", "注册项目", DWORD(BS_PUSHBUTTON), 0, parent, instance, registerID)
      removeButton = createChild(
        "BUTTON", "移除项目", DWORD(BS_PUSHBUTTON), 0, parent, instance, removeID)
      saveButton = createChild("BUTTON", "保存策略", DWORD(BS_PUSHBUTTON), 0, parent, instance, saveID)
      refreshButton = createChild(
        "BUTTON", "刷新", DWORD(BS_PUSHBUTTON), 0, parent, instance, refreshID)
      browseButton = createChild(
        "BUTTON", "浏览…", DWORD(BS_PUSHBUTTON), 0, parent, instance, browseID)
      setCombo(readCombo, values: readValues, selected: "allowed")
      setCombo(writeCombo, values: writeValues, selected: "requiresLocalApproval")
      setCombo(networkCombo, values: writeValues, selected: "denied")
      _ = EnableWindow(registerButton, false)
      _ = EnableWindow(removeButton, false)
      _ = EnableWindow(saveButton, false)
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let leftWidth = Int32(268)
      let rightX = padding + leftWidth + 12
      let rightWidth = max(Int32(100), width - rightX - padding)
      let listTop = Int32(22)
      let listHeight = min(Int32(224), max(Int32(140), height / 2))
      let formTop = listTop + listHeight + 28
      _ = MoveWindow(nameLabel, padding, formTop + 3, 58, 20, true)
      _ = MoveWindow(nameInput, 74, formTop, 194, 24, true)
      _ = MoveWindow(pathLabel, rightX, formTop + 3, 76, 20, true)
      _ = MoveWindow(pathInput, rightX + 76, formTop, rightWidth - 148, 24, true)
      _ = MoveWindow(browseButton, rightX + rightWidth - 66, formTop, 66, 24, true)
      _ = MoveWindow(readLabel, padding, formTop + 37, 58, 20, true)
      _ = MoveWindow(readCombo, 74, formTop + 34, 194, 160, true)
      _ = MoveWindow(writeLabel, rightX, formTop + 37, 58, 20, true)
      _ = MoveWindow(writeCombo, rightX + 76, formTop + 34, 194, 160, true)
      _ = MoveWindow(networkLabel, padding, formTop + 71, 58, 20, true)
      _ = MoveWindow(networkCombo, 74, formTop + 68, 194, 160, true)
      _ = MoveWindow(registerButton, rightX + 282, formTop + 34, 96, 24, true)
      _ = MoveWindow(removeButton, rightX + 282, formTop + 68, 96, 24, true)
      _ = MoveWindow(saveButton, rightX + 282, formTop + 102, 96, 24, true)
      _ = MoveWindow(refreshButton, rightX + 282, formTop + 136, 96, 24, true)
      _ = MoveWindow(status, padding, formTop + 110, leftWidth, 56, true)
      _ = MoveWindow(listBox, padding, listTop, leftWidth, listHeight, true)
      _ = MoveWindow(detail, rightX, listTop, rightWidth, listHeight, true)
    }
  }
#endif
