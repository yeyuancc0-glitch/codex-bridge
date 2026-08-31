#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  enum WindowsSettingsWindow {
    private static let className = "CodexBridgeSettingsWindow"
    private static let title = "Codex Bridge · 设置"
    static let executionModelID = 6901
    static let supervisorModelID = 6902
    static let executionEffortID = 6903
    static let supervisorEffortID = 6904
    static let accessID = 6905
    static let supervisorEnabledID = 6906
    static let fastModeID = 6907
    static let directApprovalID = 6908
    static let taskStartApprovalID = 6909
    static let instructionsID = 6910
    static let statusID = 6911
    static let savePreferencesID = 7001
    static let saveInstructionsID = 7002
    static let saveDirectApprovalID = 7003
    static let saveTaskStartApprovalID = 7004
    static let refreshID = 7005

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var executionModel: HWND?
    nonisolated(unsafe) static var supervisorModel: HWND?
    nonisolated(unsafe) static var executionEffort: HWND?
    nonisolated(unsafe) static var supervisorEffort: HWND?
    nonisolated(unsafe) static var access: HWND?
    nonisolated(unsafe) static var supervisorEnabled: HWND?
    nonisolated(unsafe) static var fastMode: HWND?
    nonisolated(unsafe) static var directApproval: HWND?
    nonisolated(unsafe) static var taskStartApproval: HWND?
    nonisolated(unsafe) static var instructions: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var modelIDs: [String] = []
    nonisolated(unsafe) static var effortValues: [String] = []
    nonisolated(unsafe) static var accessValues: [String] = []
    nonisolated(unsafe) static var approvalValues: [String] = []

    static func show(owner: HWND?) {
      if let window {
        _ = ShowWindow(window, SW_SHOW)
        _ = SetForegroundWindow(window)
        return
      }
      let instance = GetModuleHandleW(nil)!
      registerClass(instance)
      guard let created = createWindow(owner: owner, instance: instance) else { return }
      window = created
      createControls(parent: created, instance: instance)
      layout()
      _ = ShowWindow(created, SW_SHOW)
      _ = SetForegroundWindow(created)
    }

    static func shutdown() {
      guard let window else { return }
      _ = DestroyWindow(window)
      self.window = nil
      executionModel = nil
      supervisorModel = nil
      executionEffort = nil
      supervisorEffort = nil
      access = nil
      supervisorEnabled = nil
      fastMode = nil
      directApproval = nil
      taskStartApproval = nil
      instructions = nil
      status = nil
      modelIDs = []
      effortValues = []
      accessValues = []
      approvalValues = []
    }

    static func apply(_ display: WindowsSettingsDisplay) {
      guard window != nil else { return }
      modelIDs = display.modelIDs
      effortValues = display.effortValues
      accessValues = display.accessValues
      approvalValues = display.directApprovalValues
      WindowsAuxiliaryControlSupport.setCombo(
        executionModel,
        values: display.modelRows,
        selectedIndex: display.selectedExecutionModelIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        supervisorModel,
        values: display.modelRows,
        selectedIndex: display.selectedSupervisorModelIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        executionEffort,
        values: display.effortValues.map(DirectWorkspacePresentation.effortLabel),
        selectedIndex: display.selectedExecutionEffortIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        supervisorEffort,
        values: display.effortValues.map(DirectWorkspacePresentation.effortLabel),
        selectedIndex: display.selectedSupervisorEffortIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        access,
        values: display.accessValues.map(DirectWorkspacePresentation.accessModeLabel),
        selectedIndex: display.selectedAccessIndex
      )
      WindowsAuxiliaryControlSupport.setChecked(supervisorEnabled, display.supervisorEnabled)
      _ = EnableWindow(supervisorEnabled, false)
      WindowsAuxiliaryControlSupport.setChecked(fastMode, display.fastModeEnabled)
      WindowsAuxiliaryControlSupport.setCombo(
        directApproval,
        values: display.directApprovalValues.map(approvalLabel),
        selectedIndex: display.selectedDirectApprovalIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        taskStartApproval,
        values: display.taskStartApprovalValues.map(approvalLabel),
        selectedIndex: display.selectedTaskStartApprovalIndex
      )
      WindowsAuxiliaryControlSupport.setText(instructions, display.customInstructions)
      WindowsAuxiliaryControlSupport.setText(status, display.statusText)
      _ = EnableWindow(savePreferencesButton, display.savePreferencesEnabled)
      _ = EnableWindow(saveInstructionsButton, display.saveInstructionsEnabled)
      _ = EnableWindow(saveDirectApprovalButton, display.saveDirectApprovalEnabled)
      _ = EnableWindow(saveTaskStartApprovalButton, display.saveTaskStartApprovalEnabled)
    }

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        if let command = command(for: wParam) {
          WindowsMainWindow.enqueue(command)
          return 0
        }
        return DefWindowProcW(window, message, wParam, lParam)
      case UINT(WM_SIZE):
        layout()
        return 0
      case UINT(WM_CLOSE):
        _ = ShowWindow(window, SW_HIDE)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    private static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      guard notification == WPARAM(BN_CLICKED) else { return nil }
      switch id {
      case WPARAM(savePreferencesID):
        return savePreferencesCommand()
      case WPARAM(saveInstructionsID):
        return .saveSettingsInstructions(
          text: WindowsAuxiliaryControlSupport.currentText(instructions))
      case WPARAM(saveDirectApprovalID):
        return .setSettingsDirectApprovalMode(
          mode: selectedValue(directApproval, values: approvalValues))
      case WPARAM(saveTaskStartApprovalID):
        return .setSettingsTaskStartApprovalMode(
          mode: selectedValue(taskStartApproval, values: approvalValues))
      case WPARAM(refreshID):
        return .refreshSettings
      default:
        return nil
      }
    }

    private static func savePreferencesCommand() -> MainWindowCommand? {
      let executionIndex =
        WindowsAuxiliaryControlSupport.selectedIndex(executionModel, combo: true) ?? -1
      let supervisorIndex =
        WindowsAuxiliaryControlSupport.selectedIndex(supervisorModel, combo: true) ?? -1
      let executionEffortIndex =
        WindowsAuxiliaryControlSupport.selectedIndex(executionEffort, combo: true) ?? -1
      let supervisorEffortIndex =
        WindowsAuxiliaryControlSupport.selectedIndex(supervisorEffort, combo: true) ?? -1
      let accessIndex = WindowsAuxiliaryControlSupport.selectedIndex(access, combo: true) ?? -1
      guard modelIDs.indices.contains(executionIndex), modelIDs.indices.contains(supervisorIndex),
        effortValues.indices.contains(executionEffortIndex),
        effortValues.indices.contains(supervisorEffortIndex),
        accessValues.indices.contains(accessIndex)
      else { return nil }
      return .saveSettingsPreferences(
        preferences: IPCModelPreferences(
          executionModel: modelIDs[executionIndex],
          executionEffort: effortValues[executionEffortIndex],
          supervisorModel: modelIDs[supervisorIndex],
          supervisorEffort: effortValues[supervisorEffortIndex],
          supervisorEnabled: false,
          accessMode: accessValues[accessIndex],
          fastModeEnabled: WindowsAuxiliaryControlSupport.isChecked(fastMode)
        )
      )
    }

    private static func selectedValue(_ target: HWND?, values: [String]) -> String {
      let index = WindowsAuxiliaryControlSupport.selectedIndex(target, combo: true) ?? 0
      return values.indices.contains(index) ? values[index] : values.first ?? "require"
    }

    private static func approvalLabel(_ mode: String) -> String {
      mode == "auto" ? "自动批准" : "要求批准"
    }

    private static func createWindow(owner: HWND?, instance: HINSTANCE?) -> HWND? {
      title.withCString(encodedAs: UTF16.self) { titlePointer in
        className.withCString(encodedAs: UTF16.self) { classPointer in
          CreateWindowExW(
            DWORD(WS_EX_TOOLWINDOW),
            classPointer,
            titlePointer,
            DWORD(WS_OVERLAPPEDWINDOW),
            Int32(bitPattern: 0x8000_0000),
            Int32(bitPattern: 0x8000_0000),
            860,
            700,
            owner,
            nil,
            instance,
            nil
          )
        }
      }
    }

    private static func registerClass(_ instance: HINSTANCE) {
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsSettingsWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(nil, WindowsAuxiliaryControlSupport.resourcePointer(32_512))
        windowClass.hCursor = LoadCursorW(
          nil, WindowsAuxiliaryControlSupport.resourcePointer(32_512))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = name
        _ = RegisterClassW(&windowClass)
      }
    }
  }
#endif
