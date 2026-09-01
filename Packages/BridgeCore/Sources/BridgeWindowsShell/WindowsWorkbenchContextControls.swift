#if os(Windows)
  import WinSDK

  enum WindowsWorkbenchContextControls {
    private static let projectID = 2201
    private static let permissionID = 2202
    private static let approvalID = 2203
    private static let stopID = 2204
    private static let deleteID = 2205

    nonisolated(unsafe) private static var projectLabel: HWND?
    nonisolated(unsafe) private static var projectCombo: HWND?
    nonisolated(unsafe) private static var permissionLabel: HWND?
    nonisolated(unsafe) private static var permissionCombo: HWND?
    nonisolated(unsafe) private static var itemLabel: HWND?
    nonisolated(unsafe) private static var approvalButton: HWND?
    nonisolated(unsafe) private static var stopButton: HWND?
    nonisolated(unsafe) private static var deleteButton: HWND?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      projectLabel = child("STATIC", text: "项目", parent: parent, instance: instance, id: 2211)
      projectCombo = child(
        "COMBOBOX", style: comboStyle, parent: parent, instance: instance, id: projectID)
      permissionLabel = child(
        "STATIC", text: "权限", parent: parent, instance: instance, id: 2212)
      permissionCombo = child(
        "COMBOBOX", style: comboStyle, parent: parent, instance: instance, id: permissionID)
      itemLabel = child(
        "STATIC", text: "Agent 任务 / Codex 历史会话", parent: parent, instance: instance, id: 2213)
      approvalButton = child(
        "BUTTON", text: "待处理审批 (0)", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: approvalID)
      stopButton = child(
        "BUTTON", text: "停止", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: stopID)
      deleteButton = child(
        "BUTTON", text: "删除", style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: deleteID)
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      switch id {
      case WPARAM(projectID) where notification == WPARAM(CBN_SELCHANGE):
        return selectedComboIndex(projectCombo).map(MainWindowCommand.selectWorkbenchProject)
      case WPARAM(permissionID) where notification == WPARAM(CBN_SELCHANGE):
        return selectedComboIndex(permissionCombo).map(MainWindowCommand.selectWorkbenchPermission)
      case WPARAM(approvalID) where notification == WPARAM(BN_CLICKED):
        return .showApprovals
      case WPARAM(stopID) where notification == WPARAM(BN_CLICKED):
        return .stopSelectedTask
      case WPARAM(deleteID) where notification == WPARAM(BN_CLICKED):
        return .deleteSelectedTask
      default:
        return nil
      }
    }

    static func apply(_ display: WindowsWorkbenchDisplay) {
      WindowsAuxiliaryControlSupport.setCombo(
        projectCombo,
        values: display.projectRows,
        selectedIndex: display.selectedProjectIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        permissionCombo,
        values: display.permissionRows,
        selectedIndex: display.selectedPermissionIndex
      )
      WindowsUIFoundation.setText(
        approvalButton,
        "待处理审批 (\(display.pendingApprovalCount))"
      )
      _ = EnableWindow(approvalButton, display.pendingApprovalCount > 0)
      _ = EnableWindow(stopButton, display.stopEnabled)
      _ = EnableWindow(deleteButton, display.deleteEnabled)
    }

    static func layout(in bounds: RECT, below top: Int32) -> Int32 {
      let padding = Int32(8)
      let left = bounds.left + padding
      let width = max(Int32(0), bounds.right - bounds.left - padding * 2)
      let labelWidth = Int32(44)
      let comboLeft = left + labelWidth + 6
      let comboWidth = max(Int32(0), width - labelWidth - 6)
      _ = MoveWindow(projectLabel, left, top + 4, labelWidth, 24, true)
      _ = MoveWindow(projectCombo, comboLeft, top, comboWidth, 180, true)
      _ = MoveWindow(permissionLabel, left, top + 34, labelWidth, 24, true)
      _ = MoveWindow(permissionCombo, comboLeft, top + 30, comboWidth, 180, true)
      _ = MoveWindow(itemLabel, left, top + 64, width, 22, true)
      _ = MoveWindow(approvalButton, left, top + 88, width, 26, true)
      return top + 122
    }

    static func layoutTaskActions(in bounds: RECT, y: Int32, buttonWidth: Int32) {
      let left = bounds.left + 8
      _ = MoveWindow(stopButton, left + buttonWidth + 4, y, buttonWidth, 24, true)
      _ = MoveWindow(deleteButton, left + (buttonWidth + 4) * 2, y, buttonWidth, 24, true)
    }

    static func setVisible(_ visible: Bool) {
      for control in [
        projectLabel, projectCombo, permissionLabel, permissionCombo, itemLabel,
        approvalButton, stopButton, deleteButton,
      ] {
        WindowsUIFoundation.show(control, visible)
      }
    }

    private static var comboStyle: DWORD {
      DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL)
    }

    private static func child(
      _ className: String,
      text: String = "",
      style: DWORD = 0,
      parent: HWND?,
      instance: HINSTANCE?,
      id: Int
    ) -> HWND? {
      WindowsUIFoundation.createChild(
        className,
        text: text,
        style: style,
        parent: parent,
        instance: instance,
        id: id
      )
    }

    private static func selectedComboIndex(_ control: HWND?) -> Int? {
      WindowsAuxiliaryControlSupport.selectedIndex(control, combo: true)
    }
  }
#endif
