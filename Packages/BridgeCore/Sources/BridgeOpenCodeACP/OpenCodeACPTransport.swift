import BridgeProcess
import Foundation

public protocol OpenCodeACPTransport: Sendable {
  var incoming: AsyncThrowingStream<Data, any Error> { get }
  func send(_ frame: Data) async throws
  func close() async
}

public struct OpenCodeACPProcessTransportConfiguration: Sendable {
  public let argv: [String]
  public let workingDirectory: String
  public let environment: [String: String]
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration

  public init(
    argv: [String],
    workingDirectory: String,
    environment: [String: String],
    maximumFrameBytes: Int = 1_048_576,
    maximumStandardErrorBytes: Int = 256 * 1_024,
    maximumLifetime: Duration = .seconds(24 * 60 * 60)
  ) {
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
  }
}

public final class OpenCodeACPProcessTransport: OpenCodeACPTransport, @unchecked Sendable {
  public var incoming: AsyncThrowingStream<Data, any Error> { state.stream }

  private let process: ManagedStdioProcess
  private let state: ProcessTransportState
  private let standardError: BoundedProcessOutputCollector
  private let runner: ManagedProcessRunner
  private let maximumFrameBytes: Int
  private let lock = NSLock()
  private var closing = false
  private var monitorTask: Task<Void, Never>?

  public static func launch(
    configuration: OpenCodeACPProcessTransportConfiguration
  ) throws -> OpenCodeACPProcessTransport {
    let state = ProcessTransportState(maximumFrameBytes: configuration.maximumFrameBytes)
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
    let transport = OpenCodeACPProcessTransport(
      process: process,
      state: state,
      standardError: standardError,
      maximumFrameBytes: configuration.maximumFrameBytes,
      runner: ManagedProcessRunner(defaultTimeout: configuration.maximumLifetime)
    )
    transport.startMonitoring()
    return transport
  }

  private init(
    process: ManagedStdioProcess,
    state: ProcessTransportState,
    standardError: BoundedProcessOutputCollector,
    maximumFrameBytes: Int,
    runner: ManagedProcessRunner
  ) {
    self.process = process
    self.state = state
    self.standardError = standardError
    self.maximumFrameBytes = maximumFrameBytes
    self.runner = runner
  }

  public func send(_ frame: Data) async throws {
    guard !frame.isEmpty, frame.count <= maximumFrameBytes, !frame.contains(0x0A) else {
      throw OpenCodeACPError.oversizedFrame
    }
    let isClosing = lock.withLock { closing }
    guard !isClosing else { throw OpenCodeACPError.transportClosed }
    var line = frame
    line.append(0x0A)
    do {
      try process.writeStdin(line)
    } catch {
      throw OpenCodeACPError.transportClosed
    }
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
    if let task {
      task.cancel()
      await task.value
    } else {
      _ = process.terminateAndWait()
      process.drainRemainingOutput()
      process.close()
    }
    state.finish()
  }

  public func standardErrorSnapshot() -> BoundedProcessOutput {
    standardError.snapshot()
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

  private static func exitError(_ termination: ManagedProcessTermination) -> OpenCodeACPError {
    switch termination {
    case .exited(let code): .processExited(code)
    case .killed: .processExited(nil)
    case .notStarted: .processExited(nil)
    }
  }
}

private final class ProcessTransportState: @unchecked Sendable {
  let stream: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var decoder: ACPLineDecoder
  private var finished = false

  init(maximumFrameBytes: Int) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(256)
    )
    stream = pair.stream
    continuation = pair.continuation
    decoder = ACPLineDecoder(maximumFrameBytes: maximumFrameBytes)
  }

  func receive(_ data: Data) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    do {
      let frames = try decoder.append(data)
      lock.unlock()
      for frame in frames {
        if case .dropped = continuation.yield(frame) {
          finish(throwing: OpenCodeACPError.transportClosed)
          return
        }
      }
    } catch {
      finished = true
      lock.unlock()
      continuation.finish(throwing: error)
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
      continuation.finish(throwing: error)
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
