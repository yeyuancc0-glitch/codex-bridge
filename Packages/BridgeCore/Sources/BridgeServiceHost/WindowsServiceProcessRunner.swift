#if canImport(WinSDK)
  import BridgeCodexRPC
  import BridgeSecurity
  import Foundation
  import WinSDK

  public enum WindowsServiceProcessArgumentError: Error, Equatable, Sendable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidDataRoot
  }

  public struct WindowsServiceProcessOptions: Equatable, Sendable {
    public let foreground: Bool
    public let dataRootURL: URL

    public init(foreground: Bool, dataRootURL: URL) {
      self.foreground = foreground
      self.dataRootURL = dataRootURL
    }

    public static func parse(_ arguments: [String]) throws -> WindowsServiceProcessOptions {
      var foreground = false
      var dataRoot = ServiceDataPaths.defaultRoot()
      var index = 0
      while index < arguments.count {
        switch arguments[index] {
        case "--foreground":
          foreground = true
          index += 1
        case "--data-root":
          let valueIndex = index + 1
          guard valueIndex < arguments.count else {
            throw WindowsServiceProcessArgumentError.missingValue("--data-root")
          }
          let value = arguments[valueIndex]
          guard Self.isLocalDrivePath(value) else {
            throw WindowsServiceProcessArgumentError.invalidDataRoot
          }
          dataRoot = URL(fileURLWithPath: value, isDirectory: true)
          index += 2
        default:
          throw WindowsServiceProcessArgumentError.unknownArgument(arguments[index])
        }
      }
      return WindowsServiceProcessOptions(foreground: foreground, dataRootURL: dataRoot)
    }

    private static func isLocalDrivePath(_ value: String) -> Bool {
      guard value.utf8.count <= 16_384, !value.contains("\0"),
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return false }
      let path = value.replacingOccurrences(of: "/", with: "\\")
      let units = Array(path.utf16)
      guard units.count >= 3, units[1] == 58, units[2] == 92 else { return false }
      return (65...90).contains(Int(units[0])) || (97...122).contains(Int(units[0]))
    }
  }

  public enum WindowsServiceProcessRunner {
    public static func run(
      arguments: [String] = Array(CommandLine.arguments.dropFirst()),
      appVersion: String = "0.2.0"
    ) async throws {
      let options = try WindowsServiceProcessOptions.parse(arguments)
      let instanceLease = try WindowsServiceInstanceLease()
      let composition = try await ServiceComposition.make(
        configuration: ServiceCompositionConfiguration(
          appVersion: appVersion,
          dataRootURL: options.dataRootURL,
          clientInfo: .bridge(version: appVersion),
          appBundleURL: nil,
          legacyDataRootURL: nil
        ),
        secretStore: WindowsCredentialSecretStore()
      )
      let endpoint = try await composition.startLocalMCP()
      let controller = WindowsServiceController(composition: composition)
      controller.start()
      if options.foreground {
        FileHandle.standardOutput.write(
          Data("Codex Bridge service ready on 127.0.0.1:\(endpoint.port).\n".utf8)
        )
      }

      let termination = WindowsServiceTerminationState()
      WindowsServiceTerminationSignal.install(termination)
      await termination.wait()
      controller.stop()
      await composition.shutdown()
      termination.finish()
      WindowsServiceTerminationSignal.uninstall(termination)
      withExtendedLifetime(instanceLease) {}
    }
  }

  private enum WindowsServiceTerminationSignal {
    nonisolated(unsafe) private static var state: WindowsServiceTerminationState?
    private static let stateLock = NSLock()

    private static let handler: PHANDLER_ROUTINE = { event in
      guard [DWORD(0), DWORD(1), DWORD(2), DWORD(5), DWORD(6)].contains(event) else {
        return false
      }
      stateLock.lock()
      let active = state
      stateLock.unlock()
      active?.signal()
      if event == DWORD(2) || event == DWORD(5) || event == DWORD(6) {
        active?.waitForFinish(timeout: 4)
      }
      return true
    }

    static func install(_ next: WindowsServiceTerminationState) {
      stateLock.lock()
      state = next
      stateLock.unlock()
      _ = SetConsoleCtrlHandler(handler, true)
    }

    static func uninstall(_ installed: WindowsServiceTerminationState) {
      _ = SetConsoleCtrlHandler(handler, false)
      stateLock.lock()
      if state === installed { state = nil }
      stateLock.unlock()
    }
  }

  private final class WindowsServiceTerminationState: @unchecked Sendable {
    private let condition = NSCondition()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false
    private var finished = false

    func wait() async {
      await withCheckedContinuation { continuation in
        condition.lock()
        if signaled {
          condition.unlock()
          continuation.resume()
          return
        }
        self.continuation = continuation
        condition.unlock()
      }
    }

    func signal() {
      condition.lock()
      signaled = true
      let continuation = continuation
      self.continuation = nil
      condition.broadcast()
      condition.unlock()
      continuation?.resume()
    }

    func finish() {
      condition.lock()
      finished = true
      condition.broadcast()
      condition.unlock()
    }

    func waitForFinish(timeout: TimeInterval) {
      let deadline = Date().addingTimeInterval(timeout)
      condition.lock()
      while !finished, condition.wait(until: deadline) {}
      condition.unlock()
    }
  }
#endif
