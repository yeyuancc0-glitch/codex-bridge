#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  enum WindowsWorkspaceWindow {
    private static let className = "CodexBridgeWorkspaceWindow"
    private static let title = "Codex Bridge · Direct 工作区"
    static let projectListID = 6001
    static let commandListID = 6002
    static let commandDetailID = 6003
    static let skillListID = 6004
    static let skillDetailID = 6005
    static let modeID = 6006
    static let nameID = 6007
    static let executableID = 6008
    static let argumentsID = 6009
    static let directoryID = 6010
    static let networkID = 6011
    static let riskID = 6012
    static let statusID = 6013
    static let saveCommandID = 6101
    static let removeCommandID = 6102
    static let saveModeID = 6103
    static let refreshID = 6104

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var projectList: HWND?
    nonisolated(unsafe) static var commandList: HWND?
    nonisolated(unsafe) static var commandDetail: HWND?
    nonisolated(unsafe) static var skillList: HWND?
    nonisolated(unsafe) static var skillDetail: HWND?
    nonisolated(unsafe) static var modeCombo: HWND?
    nonisolated(unsafe) static var nameInput: HWND?
    nonisolated(unsafe) static var executableInput: HWND?
    nonisolated(unsafe) static var argumentsInput: HWND?
    nonisolated(unsafe) static var directoryInput: HWND?
    nonisolated(unsafe) static var networkButton: HWND?
    nonisolated(unsafe) static var riskCombo: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var modeValues: [String] = []
    nonisolated(unsafe) static var riskValues: [String] = []

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
      projectList = nil
      commandList = nil
      commandDetail = nil
      skillList = nil
      skillDetail = nil
      modeCombo = nil
      nameInput = nil
      executableInput = nil
      argumentsInput = nil
      directoryInput = nil
      networkButton = nil
      riskCombo = nil
      status = nil
      modeValues = []
      riskValues = []
    }

    static func apply(_ display: WindowsWorkspaceDisplay) {
      guard window != nil else { return }
      modeValues = display.commandModeValues
      riskValues = ["normal", "elevated"]
      WindowsAuxiliaryControlSupport.setRows(
        projectList,
        rows: display.projectRows,
        selectedIndex: display.selectedProjectIndex
      )
      WindowsAuxiliaryControlSupport.setRows(
        commandList,
        rows: display.commandRows,
        selectedIndex: display.selectedCommandIndex
      )
      WindowsAuxiliaryControlSupport.setRows(
        skillList,
        rows: display.skillRows,
        selectedIndex: display.selectedSkillIndex
      )
      WindowsAuxiliaryControlSupport.setText(commandDetail, display.commandDetailText)
      WindowsAuxiliaryControlSupport.setText(skillDetail, display.skillDetailText)
      WindowsAuxiliaryControlSupport.setText(nameInput, display.commandName)
      WindowsAuxiliaryControlSupport.setText(executableInput, display.commandExecutable)
      WindowsAuxiliaryControlSupport.setText(argumentsInput, display.commandArguments)
      WindowsAuxiliaryControlSupport.setText(directoryInput, display.commandWorkingDirectory)
      WindowsAuxiliaryControlSupport.setChecked(networkButton, display.commandRequiresNetwork)
      WindowsAuxiliaryControlSupport.setCombo(
        modeCombo,
        values: display.commandModeValues.map(DirectWorkspacePresentation.modeLabel),
        selectedIndex: display.commandModeValues.firstIndex(of: display.commandMode)
      )
      WindowsAuxiliaryControlSupport.setCombo(
        riskCombo,
        values: riskValues.map(riskLabel),
        selectedIndex: riskValues.firstIndex(of: display.commandRisk)
      )
      WindowsAuxiliaryControlSupport.setText(status, display.statusText)
      _ = EnableWindow(saveCommandButton, display.saveCommandEnabled)
      _ = EnableWindow(removeCommandButton, display.removeCommandEnabled)
      _ = EnableWindow(saveModeButton, display.saveModeEnabled)
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
      switch id {
      case WPARAM(projectListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(projectList) else {
          return nil
        }
        return .selectWorkspaceProject(index: index)
      case WPARAM(commandListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(commandList) else {
          return nil
        }
        return .selectWorkspaceCommand(index: index)
      case WPARAM(skillListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(skillList) else {
          return nil
        }
        return .selectWorkspaceSkill(index: index)
      case WPARAM(saveCommandID) where notification == WPARAM(BN_CLICKED):
        return .saveWorkspaceCommand(
          name: WindowsAuxiliaryControlSupport.currentText(nameInput),
          executable: WindowsAuxiliaryControlSupport.currentText(executableInput),
          arguments: WindowsAuxiliaryControlSupport.currentText(argumentsInput),
          workingDirectory: WindowsAuxiliaryControlSupport.currentText(directoryInput),
          requiresNetwork: WindowsAuxiliaryControlSupport.isChecked(networkButton),
          risk: selectedValue(riskCombo, values: riskValues)
        )
      case WPARAM(removeCommandID) where notification == WPARAM(BN_CLICKED):
        return .removeSelectedWorkspaceCommand
      case WPARAM(saveModeID) where notification == WPARAM(BN_CLICKED):
        let index = WindowsAuxiliaryControlSupport.selectedIndex(modeCombo, combo: true) ?? 0
        guard modeValues.indices.contains(index) else { return nil }
        return .setWorkspaceMode(mode: modeValues[index])
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshWorkspace
      default:
        return nil
      }
    }

    private static func selectedValue(_ target: HWND?, values: [String]) -> String {
      let index = WindowsAuxiliaryControlSupport.selectedIndex(target, combo: true) ?? 0
      return values.indices.contains(index) ? values[index] : values.first ?? "normal"
    }

    private static func riskLabel(_ value: String) -> String {
      value == "elevated" ? "高风险" : "普通"
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
            1_020,
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
          WindowsWorkspaceWindow.handleMessage(window, message, wParam, lParam)
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
