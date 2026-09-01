#if os(Windows)
  import WinSDK

  extension WindowsWorkspaceWindow {
    nonisolated(unsafe) static var projectLabel: HWND?
    nonisolated(unsafe) static var commandLabel: HWND?
    nonisolated(unsafe) static var commandDetailLabel: HWND?
    nonisolated(unsafe) static var skillLabel: HWND?
    nonisolated(unsafe) static var threadLabel: HWND?
    nonisolated(unsafe) static var modeLabel: HWND?
    nonisolated(unsafe) static var nameLabel: HWND?
    nonisolated(unsafe) static var executableLabel: HWND?
    nonisolated(unsafe) static var argumentsLabel: HWND?
    nonisolated(unsafe) static var directoryLabel: HWND?
    nonisolated(unsafe) static var saveCommandButton: HWND?
    nonisolated(unsafe) static var removeCommandButton: HWND?
    nonisolated(unsafe) static var saveModeButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?
    nonisolated(unsafe) static var blacklistLabel: HWND?
    nonisolated(unsafe) static var blacklistExecutableLabel: HWND?
    nonisolated(unsafe) static var blacklistPatternLabel: HWND?
    nonisolated(unsafe) static var saveBlacklistButton: HWND?
    nonisolated(unsafe) static var removeBlacklistButton: HWND?

    static func createControls(parent: HWND, instance: HINSTANCE?) {
      createLists(parent: parent, instance: instance)
      createEditor(parent: parent, instance: instance)
      createActions(parent: parent, instance: instance)
    }

    private static func createLists(parent: HWND, instance: HINSTANCE?) {
      projectLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "项目", parent: parent, instance: instance, id: 6201)
      commandLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "Direct 命令", parent: parent, instance: instance, id: 6202)
      commandDetailLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "命令详情", parent: parent, instance: instance, id: 6210)
      skillLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "Skills（只读发现）", parent: parent, instance: instance, id: 6203)
      projectList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: projectListID
      )
      commandList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: commandListID
      )
      commandDetail = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: commandDetailID
      )
      skillList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: skillListID
      )
      skillDetail = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: skillDetailID
      )
      threadLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "Codex Threads", parent: parent, instance: instance, id: 6209)
      threadList = WindowsAuxiliaryControlSupport.createChild(
        "LISTBOX",
        style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: threadListID
      )
      threadDetail = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: threadDetailID
      )
    }

    private static func createEditor(parent: HWND, instance: HINSTANCE?) {
      createModeControls(parent: parent, instance: instance)
      createFieldControls(parent: parent, instance: instance)
      createOptionControls(parent: parent, instance: instance)
    }

    private static func createModeControls(parent: HWND, instance: HINSTANCE?) {
      modeLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "命令模式", parent: parent, instance: instance, id: 6204)
      modeCombo = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: modeID
      )
    }

    private static func createFieldControls(parent: HWND, instance: HINSTANCE?) {
      nameLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "名称", parent: parent, instance: instance, id: 6205)
      nameInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: nameID
      )
      executableLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "可执行文件", parent: parent, instance: instance, id: 6206)
      executableInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: executableID
      )
      argumentsLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "参数（每行一项）", parent: parent, instance: instance, id: 6207)
      argumentsInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL) | DWORD(WS_VSCROLL),
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: argumentsID
      )
      directoryLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "工作目录", parent: parent, instance: instance, id: 6208)
      directoryInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: directoryID
      )
    }

    private static func createOptionControls(parent: HWND, instance: HINSTANCE?) {
      networkButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON",
        text: "需要网络",
        style: DWORD(BS_AUTOCHECKBOX),
        parent: parent,
        instance: instance,
        id: networkID
      )
      riskCombo = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: riskID
      )
      blacklistLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "黑名单", parent: parent, instance: instance, id: 6211)
      blacklistList = WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX", style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent, instance: instance, id: blacklistListID)
      blacklistExecutableLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "可执行文件", parent: parent, instance: instance, id: 6212)
      blacklistExecutableInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT", style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: blacklistExecutableID)
      blacklistPatternLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: "参数子串", parent: parent, instance: instance, id: 6213)
      blacklistPatternInput = WindowsAuxiliaryControlSupport.createChild(
        "EDIT", style: WindowsAuxiliaryControlSupport.inputStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: blacklistPatternID)
    }

    private static func createActions(parent: HWND, instance: HINSTANCE?) {
      saveCommandButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "保存命令", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: saveCommandID
      )
      removeCommandButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "移除命令", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: removeCommandID
      )
      saveModeButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "保存模式", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: saveModeID
      )
      refreshButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "刷新", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: refreshID
      )
      saveBlacklistButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "保存黑名单", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: saveBlacklistID)
      removeBlacklistButton = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "移除黑名单", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: removeBlacklistID)
      status = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", parent: parent, instance: instance, id: statusID
      )
      WindowsAuxiliaryControlSupport.setCombo(
        riskCombo, values: ["普通", "高风险"], selectedIndex: 0)
      _ = EnableWindow(saveCommandButton, false)
      _ = EnableWindow(removeCommandButton, false)
      _ = EnableWindow(saveModeButton, false)
      _ = EnableWindow(saveBlacklistButton, false)
      _ = EnableWindow(removeBlacklistButton, false)
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(10)
      let gap = Int32(8)
      let topHeight = min(Int32(170), max(Int32(130), height / 4))
      let column = max(Int32(120), (width - padding * 2 - gap * 2) / 3)
      let secondX = padding + column + gap
      let thirdX = secondX + column + gap
      let thirdWidth = max(Int32(120), width - thirdX - padding)
      let skillTop = topHeight + 32
      let skillHeight = min(Int32(90), max(Int32(70), height / 8))
      let formTop = skillTop + skillHeight + 30
      let inputWidth = max(Int32(100), (width - padding * 2 - gap) / 2)
      let rightInputX = padding + inputWidth + gap
      let blacklistTop = formTop + 150
      let footerTop = max(blacklistTop + 34, height - 58)

      _ = MoveWindow(projectLabel, padding, 4, column, 20, true)
      _ = MoveWindow(commandLabel, secondX, 4, column, 20, true)
      _ = MoveWindow(commandDetailLabel, thirdX, 4, thirdWidth, 20, true)
      _ = MoveWindow(projectList, padding, 24, column, topHeight, true)
      _ = MoveWindow(commandList, secondX, 24, column, topHeight, true)
      _ = MoveWindow(commandDetail, thirdX, 24, thirdWidth, topHeight, true)
      let lowerColumn = max(Int32(100), (width - padding * 2 - gap * 3) / 4)
      let lowerSecondX = padding + lowerColumn + gap
      let lowerThirdX = lowerSecondX + lowerColumn + gap
      let lowerFourthX = lowerThirdX + lowerColumn + gap
      _ = MoveWindow(skillLabel, padding, skillTop - 22, lowerColumn, 20, true)
      _ = MoveWindow(skillList, padding, skillTop, lowerColumn, skillHeight, true)
      _ = MoveWindow(skillDetail, lowerSecondX, skillTop, lowerColumn, skillHeight, true)
      _ = MoveWindow(threadLabel, lowerThirdX, skillTop - 22, lowerColumn, 20, true)
      _ = MoveWindow(threadList, lowerThirdX, skillTop, lowerColumn, skillHeight, true)
      _ = MoveWindow(
        threadDetail, lowerFourthX, skillTop, width - lowerFourthX - padding, skillHeight, true)
      _ = MoveWindow(modeLabel, padding, formTop, 68, 20, true)
      _ = MoveWindow(modeCombo, padding + 72, formTop - 2, 160, 160, true)
      _ = MoveWindow(saveModeButton, padding + 242, formTop - 2, 90, 24, true)
      _ = MoveWindow(nameLabel, padding, formTop + 32, 68, 20, true)
      _ = MoveWindow(nameInput, padding + 72, formTop + 30, inputWidth - 72, 24, true)
      _ = MoveWindow(executableLabel, rightInputX, formTop + 32, 84, 20, true)
      _ = MoveWindow(
        executableInput, rightInputX + 88, formTop + 30, width - rightInputX - 88 - padding, 24,
        true)
      _ = MoveWindow(argumentsLabel, padding, formTop + 64, 100, 20, true)
      _ = MoveWindow(
        argumentsInput, padding + 104, formTop + 62, width - padding * 2 - 104, 48, true)
      _ = MoveWindow(directoryLabel, padding, formTop + 118, 68, 20, true)
      _ = MoveWindow(directoryInput, padding + 72, formTop + 116, inputWidth - 72, 24, true)
      _ = MoveWindow(networkButton, rightInputX, formTop + 116, 100, 24, true)
      _ = MoveWindow(riskCombo, rightInputX + 108, formTop + 116, 120, 160, true)
      _ = MoveWindow(blacklistLabel, padding, blacklistTop + 3, 58, 20, true)
      _ = MoveWindow(blacklistList, padding + 62, blacklistTop, 180, 160, true)
      _ = MoveWindow(blacklistExecutableLabel, padding + 252, blacklistTop + 3, 76, 20, true)
      _ = MoveWindow(blacklistExecutableInput, padding + 330, blacklistTop, 160, 24, true)
      _ = MoveWindow(blacklistPatternLabel, padding + 500, blacklistTop + 3, 68, 20, true)
      _ = MoveWindow(
        blacklistPatternInput, padding + 570, blacklistTop, max(Int32(100), width - 790), 24, true)
      _ = MoveWindow(saveBlacklistButton, width - 210, blacklistTop, 96, 24, true)
      _ = MoveWindow(removeBlacklistButton, width - 108, blacklistTop, 96, 24, true)
      _ = MoveWindow(saveCommandButton, padding, footerTop, 92, 24, true)
      _ = MoveWindow(removeCommandButton, padding + 100, footerTop, 92, 24, true)
      _ = MoveWindow(refreshButton, padding + 200, footerTop, 74, 24, true)
      _ = MoveWindow(status, padding + 284, footerTop + 2, width - padding - 284, 36, true)
    }
  }
#endif
