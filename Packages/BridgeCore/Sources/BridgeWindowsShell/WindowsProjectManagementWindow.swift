#if os(Windows)
  import Foundation
  import BridgeServiceAppCore
  import WinSDK

  enum WindowsProjectManagementWindow {
    private static let className = "CodexBridgeProjectManagementWindow"
    private static let title = "Codex Bridge · 项目管理"
    static let listID = 4001
    static let detailID = 4002
    static let statusID = 4003
    static let nameID = 4004
    static let pathID = 4005
    static let readID = 4006
    static let writeID = 4007
    static let networkID = 4008
    static let nameLabelID = 4010
    static let pathLabelID = 4011
    static let readLabelID = 4012
    static let writeLabelID = 4013
    static let networkLabelID = 4014
    static let registerID = 4101
    static let removeID = 4102
    static let saveID = 4103
    static let refreshID = 4104
    static let browseID = 4105
    static let readValues = ["denied", "allowed"]
    static let writeValues = ["denied", "requiresLocalApproval", "allowed"]

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var listBox: HWND?
    nonisolated(unsafe) static var detail: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var nameInput: HWND?
    nonisolated(unsafe) static var pathInput: HWND?
    nonisolated(unsafe) static var readCombo: HWND?
    nonisolated(unsafe) static var writeCombo: HWND?
    nonisolated(unsafe) static var networkCombo: HWND?
    nonisolated(unsafe) static var nameLabel: HWND?
    nonisolated(unsafe) static var pathLabel: HWND?
    nonisolated(unsafe) static var browseButton: HWND?
    nonisolated(unsafe) static var readLabel: HWND?
    nonisolated(unsafe) static var writeLabel: HWND?
    nonisolated(unsafe) static var networkLabel: HWND?

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
      listBox = nil
      detail = nil
      status = nil
      nameInput = nil
      pathInput = nil
      readCombo = nil
      writeCombo = nil
      networkCombo = nil
      nameLabel = nil
      pathLabel = nil
      browseButton = nil
      readLabel = nil
      writeLabel = nil
      networkLabel = nil
    }

    static func apply(_ display: WindowsProjectManagementDisplay) {
      guard window != nil else { return }
      setRows(display.rows, selectedIndex: display.selectedIndex)
      setText(detail, display.detailText)
      if let policy = display.policy {
        setCombo(readCombo, values: readValues, selected: policy.read)
        setCombo(writeCombo, values: writeValues, selected: policy.write)
        setCombo(networkCombo, values: writeValues, selected: policy.network)
      }
      setText(status, display.statusText)
      _ = EnableWindow(registerButton, display.registerEnabled)
      _ = EnableWindow(removeButton, display.removeEnabled)
      _ = EnableWindow(saveButton, display.savePolicyEnabled)
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
      case WPARAM(listID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = selectedIndex(listBox) else { return nil }
        return .selectProject(index: index)
      case WPARAM(registerID) where notification == WPARAM(BN_CLICKED):
        return .registerProject(name: currentText(nameInput), path: currentText(pathInput))
      case WPARAM(removeID) where notification == WPARAM(BN_CLICKED):
        return WindowsConfirmation.confirm(
          "确定从 Codex Bridge 移除所选项目吗？本地磁盘文件不会被删除。",
          title: "移除项目？",
          owner: window
        ) ? .removeSelectedProject : nil
      case WPARAM(saveID) where notification == WPARAM(BN_CLICKED):
        return .saveProjectPolicy(
          read: selectedValue(readCombo, values: readValues),
          write: selectedValue(writeCombo, values: writeValues),
          network: selectedValue(networkCombo, values: writeValues)
        )
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshProjects
      case WPARAM(browseID) where notification == WPARAM(BN_CLICKED):
        chooseProjectDirectory()
        return nil
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
            760, 540, owner, nil, instance, nil
          )
        }
      }
    }

    private static func registerClass(_ instance: HINSTANCE) {
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsProjectManagementWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(nil, resourcePointer(32_512))
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(32_512))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = name
        _ = RegisterClassW(&windowClass)
      }
    }

    private static func setRows(_ rows: [String], selectedIndex: Int?) {
      guard let listBox else { return }
      _ = SendMessageW(listBox, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { text in
          _ = SendMessageW(
            listBox,
            UINT(LB_ADDSTRING),
            0,
            LPARAM(Int(bitPattern: UnsafeRawPointer(text)))
          )
        }
      }
      if let selectedIndex {
        _ = SendMessageW(listBox, UINT(LB_SETCURSEL), WPARAM(selectedIndex), 0)
      }
    }

    static func setCombo(_ target: HWND?, values: [String], selected: String) {
      guard let target else { return }
      _ = SendMessageW(target, UINT(CB_RESETCONTENT), 0, 0)
      for value in values {
        let label = ProjectAgentPresentation.permissionLabel(value)
        label.withCString(encodedAs: UTF16.self) { text in
          _ = SendMessageW(
            target, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: UnsafeRawPointer(text))))
        }
      }
      let index = values.firstIndex(of: selected) ?? 0
      _ = SendMessageW(target, UINT(CB_SETCURSEL), WPARAM(index), 0)
    }

    private static func selectedValue(_ target: HWND?, values: [String]) -> String {
      guard let target else { return values.first ?? "denied" }
      let result = SendMessageW(target, UINT(CB_GETCURSEL), 0, 0)
      return values.indices.contains(Int(result)) ? values[Int(result)] : values.first ?? "denied"
    }

    private static func selectedIndex(_ target: HWND?) -> Int? {
      guard let target else { return nil }
      let result = SendMessageW(target, UINT(LB_GETCURSEL), 0, 0)
      return result >= 0 ? Int(result) : nil
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

    private static func chooseProjectDirectory() {
      var displayName = [WCHAR](repeating: 0, count: Int(MAX_PATH))
      let title = "选择要注册到 Codex Bridge 的项目目录"
      let selected = title.withCString(encodedAs: UTF16.self) { titlePointer in
        displayName.withUnsafeMutableBufferPointer { displayPointer in
          var info = BROWSEINFOW()
          info.hwndOwner = window
          info.pszDisplayName = displayPointer.baseAddress
          info.lpszTitle = titlePointer
          info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE)
          return SHBrowseForFolderW(&info)
        }
      }
      guard let selected else { return }
      defer { CoTaskMemFree(selected) }
      var path = [WCHAR](repeating: 0, count: Int(MAX_PATH))
      guard path.withUnsafeMutableBufferPointer({ SHGetPathFromIDListW(selected, $0.baseAddress) })
      else { return }
      let value = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
      setText(pathInput, value)
      if currentText(nameInput).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let name =
          value.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? value
        setText(nameInput, name)
      }
    }

    private static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) { pointer in
        _ = SetWindowTextW(target, pointer)
      }
    }

    static let edgeStyle = DWORD(WS_EX_CLIENTEDGE)
    static let inputStyle = DWORD(ES_AUTOHSCROLL)
    static let listStyle = DWORD(WS_VSCROLL) | DWORD(LBS_NOTIFY)
    static let comboStyle = DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL)
    static let detailStyle =
      DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL)
      | DWORD(ES_AUTOHSCROLL) | DWORD(ES_READONLY) | DWORD(WS_VSCROLL) | DWORD(WS_HSCROLL)

    nonisolated(unsafe) static var registerButton: HWND?
    nonisolated(unsafe) static var removeButton: HWND?
    nonisolated(unsafe) static var saveButton: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?

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
