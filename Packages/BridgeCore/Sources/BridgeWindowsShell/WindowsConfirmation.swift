#if os(Windows)
  import WinSDK

  enum WindowsConfirmation {
    static func confirm(_ message: String, title: String, owner: HWND?) -> Bool {
      message.withCString(encodedAs: UTF16.self) { messagePointer in
        title.withCString(encodedAs: UTF16.self) { titlePointer in
          MessageBoxW(
            owner,
            messagePointer,
            titlePointer,
            UINT(MB_YESNO) | UINT(MB_ICONWARNING) | UINT(MB_DEFBUTTON2)
          ) == IDYES
        }
      }
    }
  }
#endif
