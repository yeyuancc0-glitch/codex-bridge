#if os(Windows)
  import WinSDK

  enum WindowsConnectionWindow {
    private static let className = "CodexBridgeConnectionWindow"
    private static let title = "Codex Bridge · MCP 客户端"
    static let clientListID = 7001
    static let detailID = 7002
    static let endpointID = 7003
    static let exposureID = 7004
    static let statusID = 7005
    static let toggleID = 7101
    static let saveExposureID = 7102
    static let copyID = 7103
    static let rotateCredentialID = 7104
    static let rotateEndpointID = 7105
    static let refreshID = 7106

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var clientList: HWND?
    nonisolated(unsafe) static var detail: HWND?
    nonisolated(unsafe) static var endpoint: HWND?
    nonisolated(unsafe) static var exposureCombo: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var toggleButton: HWND?
    nonisolated(unsafe) static var saveExposureButton: HWND?
    nonisolated(unsafe) static var copyButton: HWND?
    nonisolated(unsafe) static var rotateCredentialButton: HWND?
    nonisolated(unsafe) static var rotateEndpointButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?

    static func show(owner: HWND?) {
      if let window {
        _ = ShowWindow(window, SW_SHOW)
        return
      }
      let instance = GetModuleHandleW(nil)!
      registerClass(instance)
      guard let created = createWindow(owner: owner, instance: instance) else { return }
      window = created
      createControls(parent: created, instance: instance)
      layout()
      _ = ShowWindow(created, SW_SHOW)
    }

    static func shutdown() {
      guard let window else { return }
      _ = DestroyWindow(window)
      self.window = nil
      clientList = nil
      detail = nil
      endpoint = nil
      exposureCombo = nil
      status = nil
      toggleButton = nil
      saveExposureButton = nil
      copyButton = nil
      rotateCredentialButton = nil
      rotateEndpointButton = nil
      refreshButton = nil
    }

    static func apply(_ display: WindowsConnectionDisplay) {
      guard window != nil else { return }
      WindowsAuxiliaryControlSupport.setRows(
        clientList, rows: display.clientRows, selectedIndex: display.selectedClientIndex)
      WindowsAuxiliaryControlSupport.setText(detail, display.clientDetailText)
      WindowsAuxiliaryControlSupport.setText(endpoint, display.endpointText)
      WindowsAuxiliaryControlSupport.setCombo(
        exposureCombo,
        values: display.exposureRows,
        selectedIndex: display.selectedExposureIndex
      )
      WindowsAuxiliaryControlSupport.setText(toggleButton, display.toggleTitle)
      WindowsAuxiliaryControlSupport.setText(status, display.statusText)
      _ = EnableWindow(toggleButton, display.toggleEnabled)
      _ = EnableWindow(saveExposureButton, display.saveExposureEnabled)
      _ = EnableWindow(copyButton, display.copyConfigurationEnabled)
      _ = EnableWindow(rotateCredentialButton, display.rotateCredentialEnabled)
      _ = EnableWindow(rotateEndpointButton, display.rotateEndpointEnabled)
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
      case WPARAM(clientListID) where notification == WPARAM(LBN_SELCHANGE):
        return WindowsAuxiliaryControlSupport.selectedIndex(clientList).map(
          MainWindowCommand.selectMCPClient)
      case WPARAM(toggleID) where notification == WPARAM(BN_CLICKED):
        return .toggleSelectedMCPClient
      case WPARAM(saveExposureID) where notification == WPARAM(BN_CLICKED):
        guard let index = WindowsAuxiliaryControlSupport.selectedIndex(exposureCombo, combo: true)
        else { return nil }
        return .setSelectedMCPExposure(index: index)
      case WPARAM(copyID) where notification == WPARAM(BN_CLICKED):
        return .copySelectedMCPConfiguration
      case WPARAM(rotateCredentialID) where notification == WPARAM(BN_CLICKED):
        return WindowsConfirmation.confirm(
          "现有 Qwen Studio 配置会立即失效，需要重新复制 JSON。",
          title: "重新生成 Qwen 凭证？",
          owner: window
        ) ? .rotateSelectedMCPCredential : nil
      case WPARAM(rotateEndpointID) where notification == WPARAM(BN_CLICKED):
        return WindowsConfirmation.confirm(
          "Qwen Studio 保存的旧 URL 会失效，需要重新复制 JSON。",
          title: "重新生成本地 Endpoint？",
          owner: window
        ) ? .rotateLocalMCPEndpoint : nil
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshMCPConnections
      default:
        return nil
      }
    }

    private static func createWindow(owner: HWND?, instance: HINSTANCE?) -> HWND? {
      title.withCString(encodedAs: UTF16.self) { titlePointer in
        className.withCString(encodedAs: UTF16.self) { classPointer in
          CreateWindowExW(
            DWORD(WS_EX_TOOLWINDOW), classPointer, titlePointer,
            DWORD(WS_OVERLAPPEDWINDOW),
            Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0x8000_0000),
            900, 620, owner, nil, instance, nil
          )
        }
      }
    }

    private static func registerClass(_ instance: HINSTANCE) {
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsConnectionWindow.handleMessage(window, message, wParam, lParam)
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
