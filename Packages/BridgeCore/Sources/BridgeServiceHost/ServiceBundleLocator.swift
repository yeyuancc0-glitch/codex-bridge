import Foundation
#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

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
    #if os(Windows)
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = buffer.withUnsafeMutableBufferPointer { raw in
        GetModuleFileNameW(nil, raw.baseAddress, DWORD(raw.count))
      }
      guard length > 0, length < DWORD(buffer.count) else {
        return Bundle.main.executableURL
      }
      let path = String(decoding: buffer[..<Int(length)], as: UTF16.self)
      return URL(fileURLWithPath: path)
    #else
      return posixExecutableURL() ?? Bundle.main.executableURL
    #endif
  }

  #if canImport(Darwin)
    private static func posixExecutableURL() -> URL? {
      var capacity: UInt32 = 0
      _ = _NSGetExecutablePath(nil, &capacity)
      guard capacity > 0 else { return nil }
      var buffer = [CChar](repeating: 0, count: Int(capacity))
      guard _NSGetExecutablePath(&buffer, &capacity) == 0 else {
        return nil
      }
      let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
      let path = String(
        decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
      return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
  #endif
}
