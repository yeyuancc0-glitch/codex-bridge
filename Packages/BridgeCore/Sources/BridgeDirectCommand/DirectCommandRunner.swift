import Foundation

public struct DirectCommandRunResult: Equatable, Sendable {
  public let sessionID: String
  public let termination: DirectProcessTermination
  public let output: DirectCommandOutputBuffer
  public let timedOut: Bool
}

public struct DirectCommandRunner: Sendable {
  public let maximumOutputBytes: Int
  public let defaultTimeout: Duration
  public let gracePeriod: Duration

  public init(
    maximumOutputBytes: Int = 1_048_576,
    defaultTimeout: Duration = .seconds(300),
    gracePeriod: Duration = .seconds(1)
  ) {
    self.maximumOutputBytes = maximumOutputBytes
    self.defaultTimeout = defaultTimeout
    self.gracePeriod = gracePeriod
  }

  public func monitor(
    process: DirectProcessLifetime,
    sessionID: String,
    output: DirectCommandOutputCollector,
    timeout: Duration? = nil,
    onExit: (() -> Void)? = nil
  ) async -> DirectCommandRunResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout ?? defaultTimeout)

    while true {
      if let termination = process.reapIfExited() {
        process.drainRemainingOutput()
        process.close()
        onExit?()
        return DirectCommandRunResult(
          sessionID: sessionID,
          termination: termination,
          output: output.snapshot(),
          timedOut: false
        )
      }
      if clock.now >= deadline {
        return await terminate(
          process: process,
          sessionID: sessionID,
          output: output,
          timedOut: true,
          onExit: onExit
        )
      }
      if Task.isCancelled {
        return await terminate(
          process: process,
          sessionID: sessionID,
          output: output,
          timedOut: false,
          onExit: onExit
        )
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  private func terminate(
    process: DirectProcessLifetime,
    sessionID: String,
    output: DirectCommandOutputCollector,
    timedOut: Bool,
    onExit: (() -> Void)?
  ) async -> DirectCommandRunResult {
    let termination =
      process.terminateAndWait(gracePeriod: gracePeriod)
      ?? .killed(9)
    process.drainRemainingOutput()
    process.close()
    onExit?()
    return DirectCommandRunResult(
      sessionID: sessionID,
      termination: termination,
      output: output.snapshot(),
      timedOut: timedOut
    )
  }
}
