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
      let errorValue = String(reflecting: error)
      let detail = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start (\(errorValue)): \(detail)\n".utf8)
      )
      #if os(Windows)
        _exit(EXIT_FAILURE)
      #else
        exit(EXIT_FAILURE)
      #endif
    }
  }
}
