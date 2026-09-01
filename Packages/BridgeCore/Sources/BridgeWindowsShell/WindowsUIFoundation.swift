#if os(Windows)
  import WinSDK

  enum WindowsUIFoundation {
    nonisolated(unsafe) private static var titleFont: HFONT?
    nonisolated(unsafe) private static var bodyFont: HFONT?

    static func initialize() {
      guard bodyFont == nil else { return }
      guard let stockFont = GetStockObject(DEFAULT_GUI_FONT) else { return }
      bodyFont = unsafeBitCast(stockFont, to: HFONT.self)

      var descriptor = LOGFONTW()
      let copied = withUnsafeMutablePointer(to: &descriptor) { pointer in
        GetObjectW(
          stockFont,
          Int32(MemoryLayout<LOGFONTW>.size),
          UnsafeMutableRawPointer(pointer)
        )
      }
      if copied > 0 {
        descriptor.lfHeight =
          descriptor.lfHeight < 0
          ? descriptor.lfHeight - 6
          : descriptor.lfHeight + 6
        descriptor.lfWeight = LONG(FW_BOLD)
        titleFont = CreateFontIndirectW(&descriptor)
      }
    }

    static func shutdown() {
      if let titleFont {
        _ = DeleteObject(titleFont)
      }
      titleFont = nil
      bodyFont = nil
    }

    static func applyBodyFont(to control: HWND?) {
      apply(font: bodyFont, to: control)
    }

    static func applyTitleFont(to control: HWND?) {
      apply(font: titleFont ?? bodyFont, to: control)
    }

    static func applyBodyFontRecursively(to root: HWND?) {
      applyBodyFont(to: root)
      _ = EnumChildWindows(
        root,
        { child, _ in
          WindowsUIFoundation.applyBodyFont(to: child)
          return true
        },
        0
      )
    }

    static func show(_ control: HWND?, _ visible: Bool) {
      _ = ShowWindow(control, visible ? SW_SHOW : SW_HIDE)
    }

    static func setText(_ control: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) {
        _ = SetWindowTextW(control, $0)
      }
    }

    static func createChild(
      _ className: String,
      text: String = "",
      style: DWORD = 0,
      exStyle: DWORD = 0,
      parent: HWND?,
      instance: HINSTANCE?,
      id: Int
    ) -> HWND? {
      let created = className.withCString(encodedAs: UTF16.self) { classPointer in
        text.withCString(encodedAs: UTF16.self) { textPointer in
          CreateWindowExW(
            exStyle,
            classPointer,
            textPointer,
            DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
            0,
            0,
            0,
            0,
            parent,
            HMENU(bitPattern: id),
            instance,
            nil
          )
        }
      }
      applyBodyFont(to: created)
      return created
    }

    private static func apply(font: HFONT?, to control: HWND?) {
      guard let font, let control else { return }
      _ = SendMessageW(
        control,
        UINT(WM_SETFONT),
        WPARAM(UInt(bitPattern: font)),
        LPARAM(1)
      )
    }
  }
#endif
