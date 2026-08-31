#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  enum WindowsAgentManagementWindow {
    private static let className = "CodexBridgeAgentManagementWindow"
    private static let title = "Codex Bridge · Agent 管理"
    static let providerListID = 5001
    static let providerDetailID = 5002
    static let installationListID = 5003
    static let installationDetailID = 5004
    static let executableID = 5005
    static let configurationID = 5006
    static let configHintID = 5007
    static let statusID = 5008
    static let providerLabelID = 5010
    static let installationLabelID = 5011
    static let executableLabelID = 5012
    static let configurationLabelID = 5013
    static let registerID = 5101
    static let enableID = 5102
    static let disableID = 5103
    static let reprobeID = 5104
    static let acceptID = 5105
    static let removeID = 5106
    static let refreshID = 5107

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var providerList: HWND?
    nonisolated(unsafe) static var providerDetail: HWND?
    nonisolated(unsafe) static var installationList: HWND?
    nonisolated(unsafe) static var installationDetail: HWND?
    nonisolated(unsafe) static var executableInput: HWND?
    nonisolated(unsafe) static var configurationInput: HWND?
    nonisolated(unsafe) static var configHint: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var providerLabel: HWND?
    nonisolated(unsafe) static var installationLabel: HWND?
    nonisolated(unsafe) static var executableLabel: HWND?
    nonisolated(unsafe) static var configurationLabel: HWND?
    nonisolated(unsafe) static var providerIDs: [String] = []
    nonisolated(unsafe) static var registerButton: HWND?
    nonisolated(unsafe) static var enableButton: HWND?
    nonisolated(unsafe) static var disableButton: HWND?
    nonisolated(unsafe) static var reprobeButton: HWND?
    nonisolated(unsafe) static var acceptButton: HWND?
    nonisolated(unsafe) static var removeButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?

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
      providerIDs = []
      providerList = nil
      providerDetail = nil
      installationList = nil
      installationDetail = nil
      executableInput = nil
      configurationInput = nil
      configHint = nil
      status = nil
      providerLabel = nil
      installationLabel = nil
      executableLabel = nil
      configurationLabel = nil
    }

    static func apply(_ display: WindowsAgentManagementDisplay) {
      guard window != nil else { return }
      providerIDs = display.providerIDs
      setRows(
        providerList, rows: display.providerRows, selectedIndex: display.selectedProviderIndex)
      setRows(
        installationList,
        rows: display.installationRows,
        selectedIndex: display.selectedInstallationIndex
      )
      setText(providerDetail, display.providerDetailText)
      setText(installationDetail, display.installationDetailText)
      setText(
        configHint,
        display.providerRequiresConfiguration ? "此 Provider 必须提供配置文件路径。" : "配置文件路径可留空。"
      )
      setText(status, display.statusText)
      _ = EnableWindow(registerButton, display.registerEnabled)
      _ = EnableWindow(enableButton, display.enableEnabled)
      _ = EnableWindow(disableButton, display.disableEnabled)
      _ = EnableWindow(reprobeButton, display.reprobeEnabled)
      _ = EnableWindow(acceptButton, display.acceptReplacementEnabled)
      _ = EnableWindow(removeButton, display.removeEnabled)
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
      let commandID = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      switch commandID {
      case WPARAM(providerListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = selectedIndex(providerList) else { return nil }
        return .selectAgentProvider(index: index)
      case WPARAM(installationListID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = selectedIndex(installationList) else { return nil }
        return .selectAgentInstallation(index: index)
      case WPARAM(registerID) where notification == WPARAM(BN_CLICKED):
        return .registerAgent(
          providerID: selectedProviderID(),
          executablePath: currentText(executableInput),
          configurationPath: currentText(configurationInput)
        )
      case WPARAM(enableID) where notification == WPARAM(BN_CLICKED):
        return .enableSelectedAgent
      case WPARAM(disableID) where notification == WPARAM(BN_CLICKED):
        return .disableSelectedAgent
      case WPARAM(reprobeID) where notification == WPARAM(BN_CLICKED):
        return .reprobeSelectedAgent(acceptReplacement: false)
      case WPARAM(acceptID) where notification == WPARAM(BN_CLICKED):
        return .reprobeSelectedAgent(acceptReplacement: true)
      case WPARAM(removeID) where notification == WPARAM(BN_CLICKED):
        return .removeSelectedAgent
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshAgents
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
            860, 620, owner, nil, instance, nil
          )
        }
      }
    }

    private static func registerClass(_ instance: HINSTANCE) {
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsAgentManagementWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(nil, resourcePointer(32_512))
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(32_512))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = name
        _ = RegisterClassW(&windowClass)
      }
    }

    private static func setRows(_ target: HWND?, rows: [String], selectedIndex: Int?) {
      guard let target else { return }
      _ = SendMessageW(target, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { text in
          _ = SendMessageW(
            target, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: UnsafeRawPointer(text))))
        }
      }
      if let selectedIndex {
        _ = SendMessageW(target, UINT(LB_SETCURSEL), WPARAM(selectedIndex), 0)
      }
    }

    private static func selectedIndex(_ target: HWND?) -> Int? {
      guard let target else { return nil }
      let result = SendMessageW(target, UINT(LB_GETCURSEL), 0, 0)
      return result >= 0 ? Int(result) : nil
    }

    private static func selectedProviderID() -> String {
      guard let index = selectedIndex(providerList), providerIDs.indices.contains(index) else {
        return ""
      }
      return providerIDs[index]
    }

    private static func currentText(_ target: HWND?) -> String {
      guard let target else { return "" }
      let length = GetWindowTextLengthW(target)
      guard length > 0 else { return "" }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = buffer.withUnsafeMutableBufferPointer { pointer in
        GetWindowTextW(target, pointer.baseAddress, Int32(pointer.count))
      }
      return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
    }

    private static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) { pointer in
        _ = SetWindowTextW(target, pointer)
      }
    }

    static let edgeStyle = DWORD(WS_EX_CLIENTEDGE)
    static let listStyle = DWORD(WS_VSCROLL) | DWORD(LBS_NOTIFY)
    static let inputStyle = DWORD(ES_AUTOHSCROLL)
    static let detailStyle =
      DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL)
      | DWORD(ES_AUTOHSCROLL) | DWORD(ES_READONLY) | DWORD(WS_VSCROLL) | DWORD(WS_HSCROLL)

    static func createChild(
      _ className: String, _ text: String, _ style: DWORD, _ exStyle: DWORD,
      _ parent: HWND?, _ instance: HINSTANCE?, _ id: Int
    ) -> HWND? {
      className.withCString(encodedAs: UTF16.self) { classPointer -> HWND? in
        text.withCString(encodedAs: UTF16.self) { textPointer in
          CreateWindowExW(
            exStyle, classPointer, textPointer,
            DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
            0, 0, 0, 0, parent, HMENU(bitPattern: id), instance, nil
          )
        }
      }
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
