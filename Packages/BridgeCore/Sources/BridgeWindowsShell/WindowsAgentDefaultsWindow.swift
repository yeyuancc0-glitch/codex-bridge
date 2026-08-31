#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  enum WindowsAgentDefaultsWindow {
    private static let className = "CodexBridgeAgentDefaultsWindow"
    private static let title = "Codex Bridge · Agent 默认模型"
    static let providerListID = 6301
    static let installationListID = 6302
    static let detailID = 6303
    static let modelID = 6304
    static let effortID = 6305
    static let permissionID = 6306
    static let statusID = 6307
    static let refreshModelsID = 6401
    static let saveID = 6402
    static let refreshID = 6403

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var providerList: HWND?
    nonisolated(unsafe) static var installationList: HWND?
    nonisolated(unsafe) static var detail: HWND?
    nonisolated(unsafe) static var modelCombo: HWND?
    nonisolated(unsafe) static var effortCombo: HWND?
    nonisolated(unsafe) static var permissionCombo: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var modelIDs: [String] = []
    nonisolated(unsafe) static var effortValues: [String] = []
    nonisolated(unsafe) static var permissionValues: [String] = []

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
      providerList = nil
      installationList = nil
      detail = nil
      modelCombo = nil
      effortCombo = nil
      permissionCombo = nil
      status = nil
      modelIDs = []
      effortValues = []
      permissionValues = []
    }

    static func apply(_ display: WindowsAgentDefaultsDisplay) {
      guard window != nil else { return }
      modelIDs = display.modelIDs
      effortValues = display.effortValues
      permissionValues = display.permissionValues
      WindowsAuxiliaryControlSupport.setRows(
        providerList, rows: display.providerRows, selectedIndex: display.selectedProviderIndex)
      WindowsAuxiliaryControlSupport.setRows(
        installationList,
        rows: display.installationRows,
        selectedIndex: display.selectedInstallationIndex
      )
      WindowsAuxiliaryControlSupport.setText(detail, display.installationDetailText)
      WindowsAuxiliaryControlSupport.setCombo(
        modelCombo, values: display.modelRows, selectedIndex: display.selectedModelIndex)
      WindowsAuxiliaryControlSupport.setCombo(
        effortCombo,
        values: display.effortValues.map(DirectWorkspacePresentation.effortLabel),
        selectedIndex: display.selectedEffortIndex
      )
      WindowsAuxiliaryControlSupport.setCombo(
        permissionCombo,
        values: display.permissionValues.map(permissionLabel),
        selectedIndex: display.selectedPermissionIndex
      )
      WindowsAuxiliaryControlSupport.setText(status, display.statusText)
      _ = EnableWindow(refreshModelsButton, display.refreshModelsEnabled)
      _ = EnableWindow(saveButton, display.saveEnabled)
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
      case WPARAM(providerListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(providerList) else {
          return nil
        }
        return .selectDefaultProvider(index: index)
      case WPARAM(installationListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(installationList) else {
          return nil
        }
        return .selectDefaultInstallation(index: index)
      case WPARAM(refreshModelsID) where notification == WPARAM(BN_CLICKED):
        return .refreshAgentModels
      case WPARAM(saveID) where notification == WPARAM(BN_CLICKED):
        let modelIndex = WindowsAuxiliaryControlSupport.selectedIndex(modelCombo, combo: true) ?? -1
        let effortIndex =
          WindowsAuxiliaryControlSupport.selectedIndex(effortCombo, combo: true) ?? -1
        let permissionIndex =
          WindowsAuxiliaryControlSupport.selectedIndex(permissionCombo, combo: true) ?? -1
        guard modelIDs.indices.contains(modelIndex),
          effortValues.indices.contains(effortIndex),
          permissionValues.indices.contains(permissionIndex)
        else { return nil }
        return .saveAgentDefaults(
          model: modelIDs[modelIndex],
          permissionMode: permissionValues[permissionIndex],
          effort: effortValues[effortIndex]
        )
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshAgentDefaults
      default:
        return nil
      }
    }

    private static func permissionLabel(_ value: String) -> String {
      switch value {
      case "build": "构建（受控）"
      case "plan": "计划（只读）"
      case "workspace-write": "工作区可写"
      case "read-only": "只读"
      default: value
      }
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
            780,
            570,
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
          WindowsAgentDefaultsWindow.handleMessage(window, message, wParam, lParam)
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
