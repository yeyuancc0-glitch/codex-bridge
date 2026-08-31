#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsServiceShutdownDiagnostics {
    private static let enabled =
      ProcessInfo.processInfo.environment["CODEX_BRIDGE_SHUTDOWN_DIAGNOSTICS"] == "1"

    static func record(_ stage: String) {
      guard enabled else { return }
      let url = FileManager.default.temporaryDirectory.appending(
        path: "codex-bridge-shutdown-\(GetCurrentProcessId()).log"
      )
      let data = Data("\(stage)\r\n".utf8)
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: data)
        return
      }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } catch {}
    }
  }
#endif
