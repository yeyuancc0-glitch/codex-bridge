import BridgeServiceHost
import Foundation
import WinSDK

@main
enum CodexBridgeServiceWindowsMain {
  static func main() async {
    do {
      try await WindowsServiceProcessRunner.run()
    } catch {
      let errorType = String(reflecting: type(of: error))
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start [\(errorType)]: \(error)\n".utf8)
      )
      ExitProcess(1)
    }
  }
}
