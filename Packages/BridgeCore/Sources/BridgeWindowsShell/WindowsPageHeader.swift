#if os(Windows)
  import WinSDK

  enum WindowsPageHeader {
    private static let titleID = 1301
    private static let subtitleID = 1302
    private static let refreshID = 1303

    nonisolated(unsafe) private static var title: HWND?
    nonisolated(unsafe) private static var subtitle: HWND?
    nonisolated(unsafe) private static var refreshButton: HWND?

    static func create(in parent: HWND?, instance: HINSTANCE?) {
      title = WindowsUIFoundation.createChild(
        "STATIC",
        text: WindowsMainPage.overview.title,
        parent: parent,
        instance: instance,
        id: titleID
      )
      WindowsUIFoundation.applyTitleFont(to: title)
      subtitle = WindowsUIFoundation.createChild(
        "STATIC",
        text: WindowsMainPage.overview.subtitle,
        parent: parent,
        instance: instance,
        id: subtitleID
      )
      refreshButton = WindowsUIFoundation.createChild(
        "BUTTON",
        text: "刷新",
        style: DWORD(BS_PUSHBUTTON),
        parent: parent,
        instance: instance,
        id: refreshID
      )
    }

    static func command(for wParam: WPARAM) -> MainWindowCommand? {
      let id = wParam & 0xFFFF
      let notification = (wParam >> 16) & 0xFFFF
      guard id == WPARAM(refreshID), notification == WPARAM(BN_CLICKED) else { return nil }
      return .refreshCurrentPage
    }

    static func apply(page: WindowsMainPage, statusDetail: String? = nil) {
      WindowsUIFoundation.setText(title, page.title)
      WindowsUIFoundation.setText(subtitle, statusDetail ?? page.subtitle)
    }

    static func layout(in bounds: RECT) -> RECT {
      let padding = Int32(24)
      let width = bounds.right - bounds.left
      _ = MoveWindow(title, bounds.left + padding, bounds.top + 16, width - 150, 28, true)
      _ = MoveWindow(subtitle, bounds.left + padding, bounds.top + 47, width - 160, 24, true)
      _ = MoveWindow(refreshButton, bounds.right - 96, bounds.top + 22, 72, 30, true)
      return RECT(
        left: bounds.left,
        top: bounds.top + 82,
        right: bounds.right,
        bottom: bounds.bottom
      )
    }
  }
#endif
