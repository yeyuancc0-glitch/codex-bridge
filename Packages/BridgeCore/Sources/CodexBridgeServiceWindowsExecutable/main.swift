import BridgeServiceHost
import Foundation
import WinSDK

@main
enum CodexBridgeServiceWindowsMain {
  static func main() async {
    do {
      try await WindowsServiceProcessRunner.run()
    } catch {
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start.\n".utf8)
      )
      ExitProcess(1)
    }
  }
}
