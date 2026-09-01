#if os(Windows)
  import WinSDK

  enum WindowsClipboard {
    static func write(_ text: String, owner: HWND?) -> Bool {
      let units = Array(text.utf16) + [0]
      let byteCount = units.count * MemoryLayout<UInt16>.size
      guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(byteCount)) else { return false }
      guard let destination = GlobalLock(memory) else {
        _ = GlobalFree(memory)
        return false
      }
      units.withUnsafeBytes { bytes in
        guard let source = bytes.baseAddress else { return }
        destination.copyMemory(from: source, byteCount: byteCount)
      }
      _ = GlobalUnlock(memory)

      guard OpenClipboard(owner) else {
        _ = GlobalFree(memory)
        return false
      }
      defer { _ = CloseClipboard() }
      _ = EmptyClipboard()
      guard SetClipboardData(UINT(CF_UNICODETEXT), memory) != nil else {
        _ = GlobalFree(memory)
        return false
      }
      return true
    }
  }
#endif
