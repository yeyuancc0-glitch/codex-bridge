#if os(Windows)
  import Foundation

  enum WindowsIPCTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sequence = 0

    static func record(_ event: String) {
      guard
        let path = ProcessInfo.processInfo.environment["CODEX_BRIDGE_IPC_TRACE"],
        !path.isEmpty
      else { return }
      lock.lock()
      defer { lock.unlock() }
      sequence += 1
      let line = "[DEBUG-IPC-\(sequence)] \(event)\r\n"
      if !FileManager.default.fileExists(atPath: path) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
      }
      guard let handle = FileHandle(forWritingAtPath: path) else { return }
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
    }
  }
#endif
