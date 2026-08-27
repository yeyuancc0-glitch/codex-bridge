import BridgeProcess
import Foundation

public protocol AntigravityCLITransport: Sendable {
  var incoming: AsyncThrowingStream<Data, any Error> { get }
  func send(_ frame: Data) async throws
  func interrupt() async
  func standardErrorSnapshot() async -> BoundedProcessOutput
  func close() async
}

public typealias AntigravityCLITransportFactory =
  @Sendable (AntigravityCLILaunchConfiguration) throws -> any AntigravityCLITransport

public final class AntigravityCLIProcessTransport: AntigravityCLITransport, @unchecked Sendable {
  public var incoming: AsyncThrowingStream<Data, any Error> { state.stream }

  private let process: ManagedStdioProcess
  private let state: AntigravityProcessTransportState
  private let standardError: BoundedProcessOutputCollector
  private let runner: ManagedProcessRunner
  private let maximumFrameBytes: Int
  private let standardInputTimeout: Duration
  private let lock = NSLock()
  private var closing = false
  private var monitorTask: Task<Void, Never>?

  public static func launch(
    configuration: AntigravityCLIProcessConfiguration
  ) throws -> AntigravityCLIProcessTransport {
    let state = AntigravityProcessTransportState(
      maximumFrameBytes: configuration.maximumFrameBytes
    )
    let standardError = BoundedProcessOutputCollector(
      maximumBytes: configuration.maximumStandardErrorBytes
    )
    let process = try ManagedStdioProcess(
      argv: configuration.argv,
      workingDirectory: configuration.workingDirectory,
      environment: configuration.environment,
      mergeStandardError: false,
      onStandardOutput: { state.receive($0) },
      onStandardError: { standardError.append($0) }
    )
    let transport = AntigravityCLIProcessTransport(
      process: process,
      state: state,
      standardError: standardError,
      maximumFrameBytes: configuration.maximumFrameBytes,
      standardInputTimeout: configuration.standardInputTimeout,
      runner: ManagedProcessRunner(defaultTimeout: configuration.maximumLifetime)
    )
    transport.startMonitoring()
    return transport
  }

  private init(
    process: ManagedStdioProcess,
    state: AntigravityProcessTransportState,
    standardError: BoundedProcessOutputCollector,
    maximumFrameBytes: Int,
    standardInputTimeout: Duration,
    runner: ManagedProcessRunner
  ) {
    self.process = process
    self.state = state
    self.standardError = standardError
    self.maximumFrameBytes = maximumFrameBytes
    self.standardInputTimeout = standardInputTimeout
    self.runner = runner
  }

  public func send(_ frame: Data) async throws {
    guard !frame.isEmpty, frame.count <= maximumFrameBytes, !frame.contains(0x0A) else {
      throw AntigravityCLIError.oversizedFrame
    }
    guard !lock.withLock({ closing }) else {
      throw AntigravityCLIError.transportClosed
    }
    var framed = frame
    framed.append(0x0A)
    let line = framed
    let timeout = standardInputTimeout
    do {
      try await Task.detached(priority: .utility) { [process] in
        try process.writeStdin(line, timeout: timeout)
      }.value
    } catch {
      process.terminateGroup()
      throw AntigravityCLIError.transportClosed
    }
  }

  public func interrupt() async {
    process.interruptGroup()
  }

  public func standardErrorSnapshot() async -> BoundedProcessOutput {
    standardError.snapshot()
  }

  public func close() async {
    let closeState = lock.withLock { () -> (Bool, Task<Void, Never>?) in
      guard !closing else { return (false, nil) }
      closing = true
      return (true, monitorTask)
    }
    guard closeState.0 else { return }
    let task = closeState.1

    process.closeStdin()
    let exited = await Task.detached(priority: .utility) { [process] in
      process.waitForExit(timeout: .seconds(2))
    }.value
    if exited == nil {
      _ = process.terminateAndWait()
    }
    task?.cancel()
    if let task { await task.value }
    process.close()
    state.finish()
  }

  private func startMonitoring() {
    let task = Task.detached { [weak self] in
      guard let self else { return }
      let result = await runner.monitor(process: process)
      let wasClosing = lock.withLock { closing }
      if wasClosing {
        state.finish()
      } else {
        state.finish(throwing: Self.exitError(result.termination))
      }
    }
    lock.withLock { monitorTask = task }
  }

  private static func exitError(_ termination: ManagedProcessTermination) -> AntigravityCLIError {
    switch termination {
    case .exited(let code): .processExited(code)
    case .killed: .processExited(nil)
    case .notStarted: .processExited(nil)
    }
  }
}

private final class AntigravityProcessTransportState: @unchecked Sendable {
  let stream: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var decoder: BoundedLineDecoder
  private var finished = false

  init(maximumFrameBytes: Int) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(256)
    )
    stream = pair.stream
    continuation = pair.continuation
    decoder = BoundedLineDecoder(maximumFrameBytes: maximumFrameBytes)
  }

  func receive(_ data: Data) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    do {
      let frames = try decoder.append(data)
      var dropped = false
      for frame in frames {
        switch continuation.yield(frame) {
        case .enqueued:
          continue
        case .dropped, .terminated:
          finished = true
          dropped = true
        @unknown default:
          finished = true
          dropped = true
        }
        break
      }
      lock.unlock()
      if dropped {
        continuation.finish(throwing: AntigravityCLIError.transportClosed)
      }
    } catch {
      finished = true
      lock.unlock()
      continuation.finish(throwing: AntigravityCLIError.oversizedFrame)
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let remaining: [Data]
    do {
      remaining = try decoder.finish()
    } catch {
      lock.unlock()
      continuation.finish(throwing: AntigravityCLIError.oversizedFrame)
      return
    }
    lock.unlock()
    for frame in remaining { _ = continuation.yield(frame) }
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }
}
