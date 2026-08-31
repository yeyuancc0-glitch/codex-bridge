#if os(Windows)
  import BridgeIPC
#endif

/// Windows desktop shell module. The Win32/WebView2 surface is implemented in
/// the Windows-only sources that live alongside this file; on macOS this
/// module compiles as an empty compatibility stub.
public enum BridgeWindowsShellInfo {
  public static let productName = "Codex Bridge"
  #if os(Windows)
    public static var windowsPipeName: String { BridgeServiceIPC.windowsPipeName }
  #else
    public static let windowsPipeName = "\\\\.\\pipe\\org.codexbridge.service"
  #endif
}
