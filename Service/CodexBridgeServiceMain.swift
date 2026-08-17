import BridgeServiceHost
import Darwin
import Foundation

@main
enum CodexBridgeBundledServiceMain {
  static func main() async {
    do {
      try await ServiceProcessRunner.run()
    } catch {
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start.\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }
}
