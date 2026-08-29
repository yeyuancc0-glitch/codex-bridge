/// Windows desktop shell module. The Win32/WebView2 surface is implemented in
/// the Windows-only sources that live alongside this file; on macOS this
/// module compiles as an empty compatibility stub.
public enum BridgeWindowsShellInfo {
  public static let productName = "Codex Bridge"
  public static let windowsPipeName = "\\\\.\\pipe\\org.codexbridge.service"
}
