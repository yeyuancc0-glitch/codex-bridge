#if os(Windows)
  import BridgeIPC
  import Foundation
  import WinSDK

  /// Ensures the background service (`codex-bridge-service.exe`, built from the
  /// same package) is listening on the IPC pipe, launching it detached from the
  /// shell's own directory when it is not.
  enum WindowsServiceLauncher {
    private static let serviceExecutableName = "codex-bridge-service.exe"
    private static let pipeReadyPollCount = 50
    private static let pipeReadyPollIntervalMs: DWORD = 200

    /// Returns true when the service pipe accepts connections, launching the
    /// service process first if necessary. Blocks for up to ~10s while polling.
    static func ensureServiceRunning() -> Bool {
      if isPipeAvailable() { return true }
      guard launchServiceProcess() else { return false }
      for _ in 0..<pipeReadyPollCount {
        Sleep(pipeReadyPollIntervalMs)
        if isPipeAvailable() { return true }
      }
      return false
    }

    /// Opening the pipe with the same access the real client uses both probes
    /// the server and (on ERROR_PIPE_BUSY) proves one exists.
    static func isPipeAvailable() -> Bool {
      BridgeServiceIPC.windowsPipeName.withCString(encodedAs: UTF16.self) { name in
        let handle = CreateFileW(
          name,
          GENERIC_READ | GENERIC_WRITE,
          0,
          nil,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
        if handle == INVALID_HANDLE_VALUE {
          return GetLastError() == ERROR_PIPE_BUSY
        }
        _ = CloseHandle(handle)
        return true
      }
    }

    private static func launchServiceProcess() -> Bool {
      guard let executablePath = serviceExecutablePath() else { return false }
      var startupInfo = STARTUPINFOW()
      startupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      var processInfo = PROCESS_INFORMATION()

      // The command line may be written by the OS, hence the mutable cast
      // (same pattern as swift-corelibs-foundation's Process).
      let launched = executablePath.withCString(encodedAs: UTF16.self) { applicationName in
        executablePath.withCString(encodedAs: UTF16.self) { commandLine in
          CreateProcessW(
            applicationName,
            UnsafeMutablePointer<WCHAR>(mutating: commandLine),
            nil,
            nil,
            false,
            DWORD(CREATE_NO_WINDOW) | DWORD(DETACHED_PROCESS),
            nil,
            nil,
            &startupInfo,
            &processInfo
          )
        }
      }
      guard launched else { return false }
      _ = CloseHandle(processInfo.hProcess)
      _ = CloseHandle(processInfo.hThread)
      return true
    }

    private static func serviceExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 1024)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      let executable = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
      guard let directoryEnd = executable.lastIndex(of: "\\") else { return nil }
      return executable[..<directoryEnd] + "\\" + serviceExecutableName
    }
  }
#endif
