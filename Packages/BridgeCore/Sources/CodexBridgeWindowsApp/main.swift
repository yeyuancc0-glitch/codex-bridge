#if os(Windows)
  import BridgeWindowsShell
  import Dispatch
  import WinSDK
  import ucrt

  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--ensure-service"] {
    _exit(WindowsApplicationControl.ensureServiceRunning() ? EXIT_SUCCESS : EXIT_FAILURE)
  }
  if arguments == ["--shutdown"] {
    _exit(WindowsApplicationControl.shutdownRunningApplication() ? EXIT_SUCCESS : EXIT_FAILURE)
  }
  if !arguments.isEmpty { _exit(EXIT_FAILURE) }
  let comInitialization = CoInitializeEx(nil, DWORD(0x2))
  let comThreadID = GetCurrentThreadId()
  Task { @MainActor in
    await CodexBridgeWindowsApplication.main(
      comInitialization: comInitialization,
      comThreadID: comThreadID
    )
    _exit(EXIT_SUCCESS)
  }
  dispatchMain()
#else
  import Foundation

  FileHandle.standardError.write(
    Data(
      "codex-bridge-windows-app is a Windows target; build it with Scripts/build-windows.ps1.\n"
        .utf8
    )
  )
  exit(EXIT_FAILURE)
#endif
