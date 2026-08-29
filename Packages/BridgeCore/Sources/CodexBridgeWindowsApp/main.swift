#if os(Windows)
  import BridgeWindowsShell

  await CodexBridgeWindowsApplication.main()
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
