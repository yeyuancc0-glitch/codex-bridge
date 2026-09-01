#if os(Windows)
  import WinSDK

  enum WindowsBrowserToolbar {
    private static let backID = 1501
    private static let forwardID = 1502
    private static let reloadID = 1503
    private static let addressID = 1504
    private static let externalID = 1505

    nonisolated(unsafe) private static var backButton: HWND?
    nonisolated(unsafe) private static var forwardButton: HWND?
    nonisolated(unsafe) private static var reloadButton: HWND?
    nonisolated(unsafe) private static var address: HWND?
    nonisolated(unsafe) private static var externalButton: HWND?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      backButton = button("后退", id: backID, parent: parent, instance: instance)
      forwardButton = button("前进", id: forwardID, parent: parent, instance: instance)
      reloadButton = button("刷新", id: reloadID, parent: parent, instance: instance)
      address = WindowsUIFoundation.createChild(
        "STATIC",
        text: "🔒  https://chatgpt.com",
        style: DWORD(SS_CENTERIMAGE),
        exStyle: DWORD(WS_EX_CLIENTEDGE),
        parent: parent,
        instance: instance,
        id: addressID
      )
      externalButton = button(
        "在外部浏览器打开", id: externalID, parent: parent, instance: instance)
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      guard notification == WPARAM(BN_CLICKED) else { return nil }
      switch id {
      case WPARAM(backID): .browserBack
      case WPARAM(forwardID): .browserForward
      case WPARAM(reloadID): .browserReload
      case WPARAM(externalID): .openChatExternally
      default: nil
      }
    }

    static func setVisible(_ visible: Bool) {
      for control in [backButton, forwardButton, reloadButton, address, externalButton] {
        WindowsUIFoundation.show(control, visible)
      }
    }

    static func setBrowserActionsEnabled(_ enabled: Bool) {
      _ = EnableWindow(backButton, enabled)
      _ = EnableWindow(forwardButton, enabled)
      _ = EnableWindow(reloadButton, enabled)
    }

    static func layout(in bounds: RECT) -> RECT {
      let top = bounds.top + 8
      let left = bounds.left + 8
      let height = Int32(30)
      _ = MoveWindow(backButton, left, top, 58, height, true)
      _ = MoveWindow(forwardButton, left + 64, top, 58, height, true)
      _ = MoveWindow(reloadButton, left + 128, top, 58, height, true)
      _ = MoveWindow(
        address,
        left + 194,
        top,
        max(Int32(120), bounds.right - left - 194 - 148),
        height,
        true
      )
      _ = MoveWindow(externalButton, bounds.right - 142, top, 134, height, true)
      return RECT(
        left: bounds.left,
        top: top + height + 8,
        right: bounds.right,
        bottom: bounds.bottom
      )
    }

    private static func button(
      _ text: String, id: Int, parent: HWND?, instance: HINSTANCE?
    ) -> HWND? {
      WindowsUIFoundation.createChild(
        "BUTTON",
        text: text,
        style: DWORD(BS_PUSHBUTTON),
        parent: parent,
        instance: instance,
        id: id
      )
    }
  }
#endif
