import BridgeCodexRPC
import BridgeIPC
import BridgeLegacyImport
import Darwin
import Foundation

public enum ServiceProcessArgumentError: Error, Equatable, LocalizedError, Sendable {
  case unknownArgument(String)
  case missingValue(String)
  case invalidDataRoot

  public var errorDescription: String? {
    switch self {
    case .unknownArgument:
      "Codex Bridge service received an unknown argument."
    case .missingValue:
      "Codex Bridge service is missing an argument value."
    case .invalidDataRoot:
      "Codex Bridge service received an invalid data root."
    }
  }
}

public struct ServiceProcessOptions: Equatable, Sendable {
  public let foreground: Bool
  public let dataRootURL: URL

  public init(foreground: Bool, dataRootURL: URL) {
    self.foreground = foreground
    self.dataRootURL = dataRootURL
  }

  public static func parse(_ arguments: [String]) throws -> ServiceProcessOptions {
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
          throw ServiceProcessArgumentError.missingValue("--data-root")
        }
        let value = arguments[valueIndex]
        guard !value.isEmpty,
          value.hasPrefix("/"),
          value.utf8.count <= 16_384,
          !value.contains("\0"),
          value.rangeOfCharacter(from: .controlCharacters) == nil
        else {
          throw ServiceProcessArgumentError.invalidDataRoot
        }
        dataRoot = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        index += 2
      default:
        throw ServiceProcessArgumentError.unknownArgument(arguments[index])
      }
    }
    return ServiceProcessOptions(foreground: foreground, dataRootURL: dataRoot)
  }
}

public enum ServiceProcessRunner {
  public static func run(
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    appVersion: String = "0.3.0"
  ) async throws {
    _ = umask(0o077)
    let options = try ServiceProcessOptions.parse(arguments)
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: appVersion,
        dataRootURL: options.dataRootURL,
        clientInfo: .bridge(version: appVersion),
        legacyDataRootURL: LegacyConfigurationImporter.defaultSourceRoot()
      )
    )
    let endpoint = try await composition.startLocalMCP()
    let listener: BridgeServiceXPCListener?
    if options.foreground {
      listener = nil
      FileHandle.standardOutput.write(
        Data("Codex Bridge service ready on 127.0.0.1:\(endpoint.port).\n".utf8)
      )
    } else {
      let active = BridgeServiceXPCListener(
        mode: .machService(BridgeServiceIPC.machServiceName),
        composition: composition
      )
      active.resume()
      listener = active
    }

    await ServiceTerminationSignal.wait()
    listener?.invalidate()
    await composition.shutdown()
  }
}

enum ServiceTerminationSignal {
  static func wait() async {
    await wait(for: [SIGINT, SIGTERM])
  }

  static func wait(for signals: [Int32]) async {
    let state = SignalState()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        state.start(continuation: continuation, signals: signals)
      }
    } onCancel: {
      state.finish()
    }
  }
}

private final class SignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var sources: [DispatchSourceSignal] = []
  private var previousHandlers: [(signal: Int32, handler: (@convention(c) (Int32) -> Void)?)] = []
  private var finished = false

  func start(
    continuation: CheckedContinuation<Void, Never>,
    signals: [Int32]
  ) {
    lock.lock()
    if finished {
      lock.unlock()
      continuation.resume()
      return
    }
    self.continuation = continuation
    lock.unlock()

    var installedSignals: [Int32] = []
    for signal in signals where !installedSignals.contains(signal) {
      installedSignals.append(signal)
      install(signal: signal)
    }
    if Task.isCancelled {
      finish()
    }
  }

  func install(signal: Int32) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    let previousHandler = Darwin.signal(signal, SIG_IGN)
    previousHandlers.append((signal: signal, handler: previousHandler))
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
    source.setEventHandler { [self] in self.finish() }
    sources.append(source)
    source.resume()
    lock.unlock()
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    let activeSources = sources
    sources.removeAll(keepingCapacity: false)
    let handlers = previousHandlers
    previousHandlers.removeAll(keepingCapacity: false)
    lock.unlock()
    for source in activeSources { source.cancel() }
    for handler in handlers {
      _ = Darwin.signal(handler.signal, handler.handler)
    }
    continuation?.resume()
  }
}
