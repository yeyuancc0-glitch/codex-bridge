import Foundation

#if canImport(Darwin)
  import Darwin

  public enum ServiceBundleLocator {
    public static func currentAppBundleURL() -> URL? {
      guard let executable = executableURL() else { return nil }
      var candidate = executable.deletingLastPathComponent()
      while candidate.path != "/" {
        if candidate.pathExtension == "app" {
          return candidate.standardizedFileURL
        }
        candidate.deleteLastPathComponent()
      }
      return nil
    }

    private static func executableURL() -> URL? {
      var capacity: UInt32 = 0
      _ = _NSGetExecutablePath(nil, &capacity)
      guard capacity > 0 else { return Bundle.main.executableURL }
      var buffer = [CChar](repeating: 0, count: Int(capacity))
      guard _NSGetExecutablePath(&buffer, &capacity) == 0 else {
        return Bundle.main.executableURL
      }
      let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
      let path = String(
        decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
      return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
  }
#else
  #if canImport(WinSDK)
    import WinSDK

    public enum ServiceBundleLocator {
      public static func currentAppBundleURL() -> URL? {
        var capacity = 512
        while capacity <= 32_768 {
          var buffer = [WCHAR](repeating: 0, count: capacity)
          let bufferCount = DWORD(buffer.count)
          let length = GetModuleFileNameW(nil, &buffer, bufferCount)
          guard length > 0 else { return nil }
          if length < DWORD(buffer.count - 1) {
            let path = buffer.withUnsafeBufferPointer {
              String(decodingCString: $0.baseAddress!, as: UTF16.self)
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
          }
          capacity *= 2
        }
        return nil
      }
    }
  #else
    public enum ServiceBundleLocator {
      public static func currentAppBundleURL() -> URL? { nil }
    }
  #endif
#endif
