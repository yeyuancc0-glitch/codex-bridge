#if os(Windows)
  import WinSDK

  extension WindowsSettingsWindow {
    nonisolated(unsafe) static var executionLabel: HWND?
    nonisolated(unsafe) static var supervisorLabel: HWND?
    nonisolated(unsafe) static var executionEffortLabel: HWND?
    nonisolated(unsafe) static var supervisorEffortLabel: HWND?
    nonisolated(unsafe) static var accessLabel: HWND?
    nonisolated(unsafe) static var directApprovalLabel: HWND?
    nonisolated(unsafe) static var taskStartApprovalLabel: HWND?
    nonisolated(unsafe) static var instructionsLabel: HWND?
    nonisolated(unsafe) static var savePreferencesButton: HWND?
    nonisolated(unsafe) static var saveInstructionsButton: HWND?
    nonisolated(unsafe) static var saveDirectApprovalButton: HWND?
    nonisolated(unsafe) static var saveTaskStartApprovalButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?
    nonisolated(unsafe) static var lifecycleLabel: HWND?

    static func createControls(parent: HWND, instance: HINSTANCE?) {
      executionLabel = label("执行模型", parent: parent, instance: instance, id: 7101)
      supervisorLabel = label("Supervisor 模型", parent: parent, instance: instance, id: 7102)
      executionEffortLabel = label("执行强度", parent: parent, instance: instance, id: 7103)
      supervisorEffortLabel = label("Supervisor 强度", parent: parent, instance: instance, id: 7104)
      accessLabel = label("访问模式", parent: parent, instance: instance, id: 7105)
      directApprovalLabel = label("Direct 审批", parent: parent, instance: instance, id: 7106)
      taskStartApprovalLabel = label("任务启动审批", parent: parent, instance: instance, id: 7107)
      instructionsLabel = label("自定义指令", parent: parent, instance: instance, id: 7108)
      executionModel = combo(executionModelID, parent: parent, instance: instance)
      supervisorModel = combo(supervisorModelID, parent: parent, instance: instance)
      executionEffort = combo(executionEffortID, parent: parent, instance: instance)
      supervisorEffort = combo(supervisorEffortID, parent: parent, instance: instance)
      access = combo(accessID, parent: parent, instance: instance)
      directApproval = combo(directApprovalID, parent: parent, instance: instance)
      taskStartApproval = combo(taskStartApprovalID, parent: parent, instance: instance)
      supervisorEnabled = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "Supervisor（Windows 暂不支持）", style: DWORD(BS_AUTOCHECKBOX),
        parent: parent, instance: instance, id: supervisorEnabledID
      )
      fastMode = WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: "快速模式", style: DWORD(BS_AUTOCHECKBOX),
        parent: parent, instance: instance, id: fastModeID
      )
      instructions = WindowsAuxiliaryControlSupport.createChild(
        "EDIT",
        style: DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL) | DWORD(WS_VSCROLL),
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent,
        instance: instance,
        id: instructionsID
      )
      savePreferencesButton = button(
        "保存模型设置", savePreferencesID, parent: parent, instance: instance)
      saveInstructionsButton = button(
        "保存自定义指令", saveInstructionsID, parent: parent, instance: instance)
      saveDirectApprovalButton = button(
        "保存 Direct 审批", saveDirectApprovalID, parent: parent, instance: instance)
      saveTaskStartApprovalButton = button(
        "保存任务审批", saveTaskStartApprovalID, parent: parent, instance: instance)
      refreshButton = button("刷新", refreshID, parent: parent, instance: instance)
      status = WindowsAuxiliaryControlSupport.createChild(
        "STATIC", parent: parent, instance: instance, id: statusID
      )
      lifecycleLabel = WindowsAuxiliaryControlSupport.createChild(
        "STATIC",
        text: "后台服务：按需启动，关闭窗口后继续运行。Supervisor 在 Windows 版不提供。",
        parent: parent,
        instance: instance,
        id: 7110
      )
      _ = EnableWindow(savePreferencesButton, false)
      _ = EnableWindow(saveInstructionsButton, false)
      _ = EnableWindow(saveDirectApprovalButton, false)
      _ = EnableWindow(saveTaskStartApprovalButton, false)
      _ = EnableWindow(supervisorEnabled, false)
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let gap = Int32(10)
      let half = max(Int32(160), (width - padding * 2 - gap) / 2)
      let rightX = padding + half + gap
      let labelWidth = Int32(108)
      let inputWidth = half - labelWidth
      let top = Int32(18)
      _ = MoveWindow(executionLabel, padding, top + 3, labelWidth, 20, true)
      _ = MoveWindow(executionModel, padding + labelWidth, top, inputWidth, 160, true)
      _ = MoveWindow(supervisorLabel, rightX, top + 3, labelWidth, 20, true)
      _ = MoveWindow(supervisorModel, rightX + labelWidth, top, inputWidth, 160, true)
      _ = MoveWindow(executionEffortLabel, padding, top + 37, labelWidth, 20, true)
      _ = MoveWindow(executionEffort, padding + labelWidth, top + 34, inputWidth, 160, true)
      _ = MoveWindow(supervisorEffortLabel, rightX, top + 37, labelWidth, 20, true)
      _ = MoveWindow(supervisorEffort, rightX + labelWidth, top + 34, inputWidth, 160, true)
      _ = MoveWindow(accessLabel, padding, top + 71, labelWidth, 20, true)
      _ = MoveWindow(access, padding + labelWidth, top + 68, inputWidth, 160, true)
      _ = MoveWindow(supervisorEnabled, rightX, top + 68, 150, 24, true)
      _ = MoveWindow(fastMode, rightX + 160, top + 68, 100, 24, true)
      let approvalTop = top + 112
      _ = MoveWindow(directApprovalLabel, padding, approvalTop + 3, labelWidth, 20, true)
      _ = MoveWindow(directApproval, padding + labelWidth, approvalTop, inputWidth, 160, true)
      _ = MoveWindow(taskStartApprovalLabel, rightX, approvalTop + 3, labelWidth, 20, true)
      _ = MoveWindow(taskStartApproval, rightX + labelWidth, approvalTop, inputWidth, 160, true)
      let instructionTop = approvalTop + 42
      _ = MoveWindow(instructionsLabel, padding, instructionTop + 3, labelWidth, 20, true)
      _ = MoveWindow(
        instructions, padding + labelWidth, instructionTop, width - padding * 2 - labelWidth, 145,
        true)
      let buttonTop = instructionTop + 158
      _ = MoveWindow(savePreferencesButton, padding, buttonTop, 112, 24, true)
      _ = MoveWindow(saveInstructionsButton, padding + 122, buttonTop, 126, 24, true)
      _ = MoveWindow(saveDirectApprovalButton, padding + 258, buttonTop, 126, 24, true)
      _ = MoveWindow(saveTaskStartApprovalButton, padding + 394, buttonTop, 126, 24, true)
      _ = MoveWindow(refreshButton, padding + 530, buttonTop, 76, 24, true)
      _ = MoveWindow(status, padding, buttonTop + 34, width - padding * 2, 42, true)
      _ = MoveWindow(lifecycleLabel, padding, buttonTop + 76, width - padding * 2, 24, true)
    }

    private static func label(_ text: String, parent: HWND, instance: HINSTANCE?, id: Int) -> HWND?
    {
      WindowsAuxiliaryControlSupport.createChild(
        "STATIC", text: text, parent: parent, instance: instance, id: id)
    }

    private static func combo(_ id: Int, parent: HWND, instance: HINSTANCE?) -> HWND? {
      WindowsAuxiliaryControlSupport.createChild(
        "COMBOBOX",
        style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent,
        instance: instance,
        id: id
      )
    }

    private static func button(_ text: String, _ id: Int, parent: HWND, instance: HINSTANCE?)
      -> HWND?
    {
      WindowsAuxiliaryControlSupport.createChild(
        "BUTTON", text: text, style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: id
      )
    }
  }
#endif
