#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsAuxiliaryControlSupport {
    static let edgeStyle = DWORD(WS_EX_CLIENTEDGE)
    static let inputStyle = DWORD(ES_AUTOHSCROLL)
    static let listStyle = DWORD(WS_VSCROLL) | DWORD(LBS_NOTIFY)
    static let comboStyle = DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL)
    static let readOnlyTextStyle =
      DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL)
      | DWORD(ES_AUTOHSCROLL) | DWORD(ES_READONLY) | DWORD(ES_WANTRETURN)
      | DWORD(WS_VSCROLL) | DWORD(WS_HSCROLL)

    static func createChild(
      _ className: String,
      text: String = "",
      style: DWORD = 0,
      exStyle: DWORD = 0,
      parent: HWND?,
      instance: HINSTANCE?,
      id: Int
    ) -> HWND? {
      className.withCString(encodedAs: UTF16.self) { classPointer in
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
    }

    static func setText(_ target: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) { pointer in
        _ = SetWindowTextW(target, pointer)
      }
    }

    static func currentText(_ target: HWND?) -> String {
      guard let target else { return "" }
      let length = GetWindowTextLengthW(target)
      guard length > 0 else { return "" }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = buffer.withUnsafeMutableBufferPointer { pointer in
        GetWindowTextW(target, pointer.baseAddress, Int32(pointer.count))
      }
      return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
    }

    static func setRows(_ target: HWND?, rows: [String], selectedIndex: Int?) {
      guard let target else { return }
      _ = SendMessageW(target, UINT(LB_RESETCONTENT), 0, 0)
      for row in rows {
        row.withCString(encodedAs: UTF16.self) { pointer in
          _ = SendMessageW(
            target,
            UINT(LB_ADDSTRING),
            0,
            LPARAM(Int(bitPattern: UnsafeRawPointer(pointer)))
          )
        }
      }
      if let selectedIndex {
        _ = SendMessageW(target, UINT(LB_SETCURSEL), WPARAM(selectedIndex), 0)
      }
    }

    static func setCombo(_ target: HWND?, values: [String], selectedIndex: Int?) {
      guard let target else { return }
      _ = SendMessageW(target, UINT(CB_RESETCONTENT), 0, 0)
      for value in values {
        value.withCString(encodedAs: UTF16.self) { pointer in
          _ = SendMessageW(
            target,
            UINT(CB_ADDSTRING),
            0,
            LPARAM(Int(bitPattern: UnsafeRawPointer(pointer)))
          )
        }
      }
      if let selectedIndex {
        _ = SendMessageW(target, UINT(CB_SETCURSEL), WPARAM(selectedIndex), 0)
      }
    }

    static func selectedIndex(_ target: HWND?, combo: Bool = false) -> Int? {
      guard let target else { return nil }
      let message = combo ? UINT(CB_GETCURSEL) : UINT(LB_GETCURSEL)
      let result = SendMessageW(target, message, 0, 0)
      return result >= 0 ? Int(result) : nil
    }

    static func setChecked(_ target: HWND?, _ checked: Bool) {
      _ = SendMessageW(
        target,
        UINT(BM_SETCHECK),
        WPARAM(checked ? BST_CHECKED : BST_UNCHECKED),
        0
      )
    }

    static func isChecked(_ target: HWND?) -> Bool {
      SendMessageW(target, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
    }

    static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
