import BridgeServiceHost
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import ucrt
#endif

@main
enum CodexBridgeServiceMain {
  static func main() async {
    do {
      try await ServiceProcessRunner.run()
    } catch {
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start.\n".utf8)
      )
      #if os(Windows)
        _exit(EXIT_FAILURE)
      #else
        exit(EXIT_FAILURE)
      #endif
    }
  }
}
