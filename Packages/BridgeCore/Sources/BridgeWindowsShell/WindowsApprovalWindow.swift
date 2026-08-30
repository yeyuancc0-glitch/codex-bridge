#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  /// Standalone Win32 approval queue. Closing this window only hides it; the
  /// main shell and its message loop remain alive.
  enum WindowsApprovalWindow {
    private static let className = "CodexBridgeApprovalWindow"
    private static let title = "Codex Bridge · 待处理审批"
    private static let listID = 3001
    private static let detailID = 3002
    private static let decisionLabelID = 3003
    private static let decisionID = 3004
    private static let allowID = 3101
    private static let denyID = 3102
    private static let refreshID = 3103
    private static let statusID = 3005

    nonisolated(unsafe) private static var window: HWND?
    nonisolated(unsafe) private static var listBox: HWND?
    nonisolated(unsafe) private static var detail: HWND?
    nonisolated(unsafe) private static var decisionLabel: HWND?
    nonisolated(unsafe) private static var decisionBox: HWND?
    nonisolated(unsafe) private static var allowButton: HWND?
    nonisolated(unsafe) private static var denyButton: HWND?
    nonisolated(unsafe) private static var refreshButton: HWND?
    nonisolated(unsafe) private static var status: HWND?
    nonisolated(unsafe) private static var decisions: [String] = []

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

    static func hide() {
      _ = ShowWindow(window, SW_HIDE)
    }

    static func shutdown() {
      guard let window else { return }
      _ = DestroyWindow(window)
      self.window = nil
      listBox = nil
      detail = nil
      decisionLabel = nil
      decisionBox = nil
      allowButton = nil
      denyButton = nil
      refreshButton = nil
      status = nil
      decisions = []
    }

    static func apply(_ display: WindowsWorkbenchDisplay) {
      guard window != nil else { return }
      setRows(display.approvalRows, selectedIndex: display.selectedApprovalIndex)
      setText(detail, display.approvalDetailText)
      setDecisionOptions(display.approvalAllowDecisions)
      setText(status, display.approvalStatusText ?? "请选择一项审批。")
      _ = EnableWindow(allowButton, display.approvalAllowEnabled)
      _ = EnableWindow(denyButton, display.approvalDenyEnabled)
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
        hide()
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
        guard let index = selectedIndex() else { return nil }
        return .selectApproval(index: index)
      case WPARAM(allowID) where notification == WPARAM(BN_CLICKED):
        return .resolveApproval(decision: selectedDecision())
      case WPARAM(denyID) where notification == WPARAM(BN_CLICKED):
        return .resolveApproval(decision: "deny")
      case WPARAM(refreshID) where notification == WPARAM(BN_CLICKED):
        return .refreshApprovals
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
            680, 520, owner, nil, instance, nil
          )
        }
      }
    }

    private static func registerClass(_ instance: HINSTANCE) {
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsApprovalWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = LoadIconW(nil, resourcePointer(32_512))
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(32_512))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = name
        _ = RegisterClassW(&windowClass)
      }
    }

    private static func createControls(parent: HWND, instance: HINSTANCE?) {
      listBox = createChild(
        "LISTBOX", "", DWORD(WS_VSCROLL) | DWORD(LBS_NOTIFY), DWORD(WS_EX_CLIENTEDGE),
        parent, instance, listID
      )
      detail = createChild(
        "EDIT", "", detailStyle, DWORD(WS_EX_CLIENTEDGE), parent, instance, detailID
      )
      decisionLabel = createChild(
        "STATIC", "允许方式：", 0, 0, parent, instance, decisionLabelID
      )
      decisionBox = createChild(
        "COMBOBOX", "", DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL), 0,
        parent, instance, decisionID
      )
      allowButton = createChild(
        "BUTTON", "允许", DWORD(BS_PUSHBUTTON), 0, parent, instance, allowID
      )
      denyButton = createChild(
        "BUTTON", "拒绝", DWORD(BS_PUSHBUTTON), 0, parent, instance, denyID
      )
      refreshButton = createChild(
        "BUTTON", "刷新", DWORD(BS_PUSHBUTTON), 0, parent, instance, refreshID
      )
      status = createChild(
        "STATIC", "请选择一项审批。", DWORD(SS_LEFTNOWORDWRAP), 0,
        parent, instance, statusID
      )
      _ = EnableWindow(allowButton, false)
      _ = EnableWindow(denyButton, false)
    }

    private static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(12)
      let contentWidth = max(Int32(0), width - padding * 2)
      let listHeight = min(Int32(180), max(Int32(110), height / 3))
      let detailTop = padding + listHeight + 8
      let footerTop = max(detailTop + 100, height - 88)
      let detailHeight = max(Int32(60), footerTop - detailTop - 8)
      let decisionTop = footerTop
      let buttonTop = decisionTop + 28

      _ = MoveWindow(listBox, padding, padding, contentWidth, listHeight, true)
      _ = MoveWindow(detail, padding, detailTop, contentWidth, detailHeight, true)
      _ = MoveWindow(decisionLabel, padding, decisionTop, 72, 24, true)
      _ = MoveWindow(decisionBox, padding + 76, decisionTop, 210, 160, true)
      _ = MoveWindow(allowButton, padding + 296, buttonTop, 76, 24, true)
      _ = MoveWindow(denyButton, padding + 378, buttonTop, 76, 24, true)
      _ = MoveWindow(refreshButton, padding + 460, buttonTop, 76, 24, true)
      _ = MoveWindow(status, padding, buttonTop + 28, contentWidth, 20, true)
    }

    private static func setRows(_ rows: [String], selectedIndex: Int?) {
      guard let listBox else { return }
      _ = SendMessageW(listBox, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { text in
          let pointer = LPARAM(Int(bitPattern: UnsafeRawPointer(text)))
          _ = SendMessageW(listBox, UINT(LB_ADDSTRING), 0, pointer)
        }
      }
      if let selectedIndex {
        _ = SendMessageW(listBox, UINT(LB_SETCURSEL), WPARAM(selectedIndex), 0)
      }
    }

    private static func setDecisionOptions(_ values: [String]) {
      guard let decisionBox else { return }
      let previous = selectedDecision()
      decisions = values
      _ = SendMessageW(decisionBox, UINT(CB_RESETCONTENT), 0, 0)
      for value in values {
        let label = ApprovalPresentation.decisionLabel(value)
        label.withCString(encodedAs: UTF16.self) { text in
          let pointer = LPARAM(Int(bitPattern: UnsafeRawPointer(text)))
          _ = SendMessageW(decisionBox, UINT(CB_ADDSTRING), 0, pointer)
        }
      }
      guard !values.isEmpty else { return }
      let index = values.firstIndex(of: previous) ?? 0
      _ = SendMessageW(decisionBox, UINT(CB_SETCURSEL), WPARAM(index), 0)
    }

    private static func selectedIndex() -> Int? {
      guard let listBox else { return nil }
      let result = SendMessageW(listBox, UINT(LB_GETCURSEL), 0, 0)
      return result >= 0 ? Int(result) : nil
    }

    private static func selectedDecision() -> String {
      guard let decisionBox else { return "" }
      let result = SendMessageW(decisionBox, UINT(CB_GETCURSEL), 0, 0)
      guard result >= 0, decisions.indices.contains(Int(result)) else { return "" }
      return decisions[Int(result)]
    }

    private static var detailStyle: DWORD {
      DWORD(ES_MULTILINE)
        | DWORD(ES_AUTOVSCROLL)
        | DWORD(ES_AUTOHSCROLL)
        | DWORD(ES_READONLY)
        | DWORD(ES_WANTRETURN)
        | DWORD(WS_VSCROLL)
        | DWORD(WS_HSCROLL)
    }

    private static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) { pointer in
        _ = SetWindowTextW(target, pointer)
      }
    }

    private static func createChild(
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
