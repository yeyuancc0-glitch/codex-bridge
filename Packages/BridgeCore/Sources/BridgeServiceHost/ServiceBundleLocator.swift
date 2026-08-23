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
  public enum ServiceBundleLocator {
    public static func currentAppBundleURL() -> URL? { nil }
  }
#endif
