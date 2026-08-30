#if os(Windows)
  import Foundation
  import WinSDK

  /// Native task list and inspector controls. Keeping these controls separate
  /// leaves the top-level window procedure focused on menus, tray, and sizing.
  enum WindowsTaskInspector {
    private static let listBoxControlID = 2001
    private static let statusControlID = 2002
    private static let chatPlaceholderControlID = 2003
    private static let metadataControlID = 2004
    private static let conversationControlID = 2005
    private static let steerInputControlID = 2006
    private static let steerLabelControlID = 2008
    private static let interruptButtonID = 2101
    private static let refreshButtonID = 2102
    private static let steerButtonID = 2103
    private static let actionStatusControlID = 2007

    nonisolated(unsafe) private static var listBox: HWND?
    nonisolated(unsafe) private static var statusStatic: HWND?
    nonisolated(unsafe) private static var chatPlaceholder: HWND?
    nonisolated(unsafe) private static var metadata: HWND?
    nonisolated(unsafe) private static var conversation: HWND?
    nonisolated(unsafe) private static var steerInput: HWND?
    nonisolated(unsafe) private static var steerLabel: HWND?
    nonisolated(unsafe) private static var interruptButton: HWND?
    nonisolated(unsafe) private static var refreshButton: HWND?
    nonisolated(unsafe) private static var steerButton: HWND?
    nonisolated(unsafe) private static var actionStatus: HWND?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      listBox = createChild(
        "LISTBOX", "", DWORD(WS_VSCROLL) | DWORD(LBS_NOTIFY), DWORD(WS_EX_CLIENTEDGE),
        parent, instance, listBoxControlID
      )
      statusStatic = createChild(
        "STATIC", "", 0, 0, parent, instance, statusControlID
      )
      chatPlaceholder = createChild(
        "STATIC", "正在加载聊天页…", 0, 0, parent, instance, chatPlaceholderControlID
      )
      metadata = createChild(
        "STATIC", "未选择任务", 0, DWORD(WS_EX_CLIENTEDGE),
        parent, instance, metadataControlID
      )
      conversation = createChild(
        "EDIT", "请从上方选择任务。", conversationStyle, DWORD(WS_EX_CLIENTEDGE),
        parent, instance, conversationControlID
      )
      steerInput = createChild(
        "EDIT", "", DWORD(ES_AUTOHSCROLL), DWORD(WS_EX_CLIENTEDGE),
        parent, instance, steerInputControlID
      )
      steerLabel = createChild(
        "STATIC", "Steer：", 0, 0, parent, instance, steerLabelControlID
      )
      interruptButton = createChild(
        "BUTTON", "中断", DWORD(BS_PUSHBUTTON), 0,
        parent, instance, interruptButtonID
      )
      refreshButton = createChild(
        "BUTTON", "刷新", DWORD(BS_PUSHBUTTON), 0,
        parent, instance, refreshButtonID
      )
      steerButton = createChild(
        "BUTTON", "发送 Steer", DWORD(BS_PUSHBUTTON), 0,
        parent, instance, steerButtonID
      )
      actionStatus = createChild(
        "STATIC", "", DWORD(SS_LEFTNOWORDWRAP), 0,
        parent, instance, actionStatusControlID
      )
      setText(conversation, "请从上方选择任务。")
      setControls(interruptEnabled: false, steerEnabled: false)
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let commandID = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      switch commandID {
      case WPARAM(listBoxControlID) where notification == WPARAM(LBN_SELCHANGE):
        guard let index = selectedTaskIndex() else { return nil }
        return .selectTask(index: index)
      case WPARAM(interruptButtonID) where notification == WPARAM(BN_CLICKED):
        return .interruptSelectedTask
      case WPARAM(refreshButtonID) where notification == WPARAM(BN_CLICKED):
        return .refreshTasks
      case WPARAM(steerButtonID) where notification == WPARAM(BN_CLICKED):
        return .submitSteer(input: currentSteerInput())
      default:
        return nil
      }
    }

    static func setTaskRows(_ rows: [String], selectedIndex: Int?) {
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

    static func setTaskMetadata(_ text: String) {
      setText(metadata, text)
    }

    static func setConversationText(_ text: String) {
      guard let conversation else { return }
      setText(conversation, text)
      let end = text.utf16.count
      _ = SendMessageW(conversation, UINT(EM_SETSEL), WPARAM(end), LPARAM(end))
      _ = SendMessageW(conversation, UINT(EM_SCROLLCARET), 0, 0)
    }

    static func setActionStatus(_ text: String?) {
      setText(actionStatus, text ?? "")
    }

    static func setControls(interruptEnabled: Bool, steerEnabled: Bool) {
      _ = EnableWindow(interruptButton, interruptEnabled)
      _ = EnableWindow(steerInput, steerEnabled)
      _ = EnableWindow(steerButton, steerEnabled)
    }

    static func setStatusText(_ text: String) {
      setText(statusStatic, text)
    }

    static func setChatPlaceholder(_ text: String?) {
      guard let chatPlaceholder else { return }
      if let text {
        setText(chatPlaceholder, text)
        _ = ShowWindow(chatPlaceholder, SW_SHOW)
      } else {
        _ = ShowWindow(chatPlaceholder, SW_HIDE)
      }
    }

    static func layout(_ window: HWND?, chat: WindowsChatWebView?) {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let sidebar = Int32(WindowLayout.sidebarWidth)
      let listHeight = max(Int32(180), height / 2)
      let inspectorTop = listHeight + 4
      let inspectorHeight = max(Int32(160), height - inspectorTop)
      let padding = Int32(6)
      let contentWidth = max(Int32(0), sidebar - padding * 2)
      let metadataHeight = min(Int32(112), max(Int32(76), inspectorHeight / 3))
      let conversationTop = inspectorTop + metadataHeight + 4
      let footerTop = max(conversationTop + 44, height - 88)
      let conversationHeight = max(Int32(40), footerTop - conversationTop - 4)
      let steerTop = footerTop
      let buttonTop = steerTop + 28
      let actionTop = buttonTop + 28

      _ = MoveWindow(listBox, 0, 0, sidebar, listHeight, true)
      _ = MoveWindow(
        metadata, padding, inspectorTop, contentWidth, metadataHeight, true
      )
      _ = MoveWindow(
        conversation, padding, conversationTop, contentWidth, conversationHeight, true
      )
      _ = MoveWindow(steerLabel, padding, steerTop, 48, 24, true)
      _ = MoveWindow(
        steerInput, padding + 50, steerTop, max(Int32(0), contentWidth - 50), 24, true
      )
      _ = MoveWindow(interruptButton, padding, buttonTop, 76, 24, true)
      _ = MoveWindow(refreshButton, padding + 82, buttonTop, 76, 24, true)
      _ = MoveWindow(steerButton, padding + 164, buttonTop, 100, 24, true)
      _ = MoveWindow(actionStatus, padding, actionTop, contentWidth, 20, true)

      let inset = Int32(WindowLayout.statusInset)
      _ = MoveWindow(
        statusStatic, sidebar + inset, inset,
        width - sidebar - inset * 2, Int32(WindowLayout.statusHeight), true
      )
      let chatTop = Int32(WindowLayout.chatTopInset)
      _ = MoveWindow(
        chatPlaceholder, sidebar, chatTop,
        width - sidebar, height - chatTop, true
      )
      chat?.resize(to: RECT(left: sidebar, top: chatTop, right: width, bottom: height))
    }

    static func selectedTaskIndex() -> Int? {
      guard let listBox else { return nil }
      let result = SendMessageW(listBox, UINT(LB_GETCURSEL), 0, 0)
      return result >= 0 ? Int(result) : nil
    }

    private static func currentSteerInput() -> String {
      guard let steerInput else { return "" }
      let length = GetWindowTextLengthW(steerInput)
      guard length > 0 else { return "" }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = buffer.withUnsafeMutableBufferPointer { pointer in
        GetWindowTextW(steerInput, pointer.baseAddress, Int32(pointer.count))
      }
      return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
    }

    static func clearSteerInput() {
      setText(steerInput, "")
    }

    private static var conversationStyle: DWORD {
      DWORD(ES_MULTILINE)
        | DWORD(ES_AUTOVSCROLL)
        | DWORD(ES_AUTOHSCROLL)
        | DWORD(ES_READONLY)
        | DWORD(ES_WANTRETURN)
        | DWORD(WS_VSCROLL)
        | DWORD(WS_HSCROLL)
    }

    private static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) {
        _ = SetWindowTextW(target, $0)
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
  }
#endif
