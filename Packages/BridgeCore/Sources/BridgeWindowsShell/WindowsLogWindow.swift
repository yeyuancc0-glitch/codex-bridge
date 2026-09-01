#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsLogWindow {
    private static let className = "CodexBridgeLogWindow"
    private static let title = "Codex Bridge · 任务日志"
    static let listID = 6701
    static let detailID = 6702
    static let statusID = 6703
    static let refreshID = 6801
    static let searchID = 6704
    static let projectFilterID = 6705
    static let kindFilterID = 6706
    static let copyID = 6802

    nonisolated(unsafe) static var window: HWND?
    nonisolated(unsafe) static var list: HWND?
    nonisolated(unsafe) static var detail: HWND?
    nonisolated(unsafe) static var status: HWND?
    nonisolated(unsafe) static var refreshButton: HWND?
    nonisolated(unsafe) static var searchInput: HWND?
    nonisolated(unsafe) static var projectFilter: HWND?
    nonisolated(unsafe) static var kindFilter: HWND?
    nonisolated(unsafe) static var copyButton: HWND?

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
      list = nil
      detail = nil
      status = nil
      refreshButton = nil
      searchInput = nil
      projectFilter = nil
      kindFilter = nil
      copyButton = nil
    }

    static func apply(_ display: WindowsLogDisplay) {
      guard window != nil else { return }
      WindowsAuxiliaryControlSupport.setRows(
        list,
        rows: display.rows,
        selectedIndex: display.selectedIndex
      )
      WindowsAuxiliaryControlSupport.setText(searchInput, display.searchText)
      WindowsAuxiliaryControlSupport.setCombo(
        projectFilter, values: display.projectRows, selectedIndex: display.selectedProjectIndex)
      WindowsAuxiliaryControlSupport.setCombo(
        kindFilter, values: display.kindRows, selectedIndex: display.selectedKindIndex)
      WindowsAuxiliaryControlSupport.setText(detail, display.detailText)
      WindowsAuxiliaryControlSupport.setText(status, display.statusText)
      _ = EnableWindow(refreshButton, display.refreshEnabled)
      _ = EnableWindow(copyButton, display.copyEnabled)
    }

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        let id = wParam & 0xFFFF
        let notification = (wParam >> 16) & 0xFFFF
        if id == WPARAM(listID), notification == WPARAM(LBN_SELCHANGE),
          let index = WindowsAuxiliaryControlSupport.selectedIndex(list)
        {
          WindowsMainWindow.enqueue(.selectLog(index: index))
          return 0
        }
        if id == WPARAM(refreshID), notification == WPARAM(BN_CLICKED) {
          WindowsMainWindow.enqueue(.refreshLogs)
          return 0
        }
        if id == WPARAM(searchID), notification == WPARAM(EN_CHANGE) {
          WindowsMainWindow.enqueue(
            .setLogSearch(text: WindowsAuxiliaryControlSupport.currentText(searchInput)))
          return 0
        }
        if id == WPARAM(projectFilterID), notification == WPARAM(CBN_SELCHANGE),
          let index = WindowsAuxiliaryControlSupport.selectedIndex(projectFilter, combo: true)
        {
          WindowsMainWindow.enqueue(.setLogProjectFilter(index: index))
          return 0
        }
        if id == WPARAM(kindFilterID), notification == WPARAM(CBN_SELCHANGE),
          let index = WindowsAuxiliaryControlSupport.selectedIndex(kindFilter, combo: true)
        {
          WindowsMainWindow.enqueue(.setLogKindFilter(index: index))
          return 0
        }
        if id == WPARAM(copyID), notification == WPARAM(BN_CLICKED) {
          WindowsMainWindow.enqueue(.copyLogs)
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
            840,
            620,
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
          WindowsLogWindow.handleMessage(window, message, wParam, lParam)
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
