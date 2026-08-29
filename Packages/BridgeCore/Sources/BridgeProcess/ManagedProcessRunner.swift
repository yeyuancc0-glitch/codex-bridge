import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct ManagedProcessRunner: Sendable {
  public let defaultTimeout: Duration
  public let gracePeriod: Duration

  public init(
    defaultTimeout: Duration = .seconds(300),
    gracePeriod: Duration = .seconds(1)
  ) {
    self.defaultTimeout = defaultTimeout
    self.gracePeriod = gracePeriod
  }

  public func monitor(
    process: ManagedStdioProcess,
    timeout: Duration? = nil
  ) async -> ManagedProcessResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout ?? defaultTimeout)

    while true {
      if let termination = process.reapIfExited() {
        process.drainRemainingOutput()
        process.close()
        return ManagedProcessResult(termination: termination, timedOut: false)
      }
      if clock.now >= deadline {
        return terminate(process: process, timedOut: true)
      }
      if Task.isCancelled {
        return terminate(process: process, timedOut: false)
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  private func terminate(
    process: ManagedStdioProcess,
    timedOut: Bool
  ) -> ManagedProcessResult {
    #if os(Windows)
      let termination = process.terminateAndWait(gracePeriod: gracePeriod) ?? .killed(9)
    #else
      let termination = process.terminateAndWait(gracePeriod: gracePeriod) ?? .killed(SIGKILL)
    #endif
    process.drainRemainingOutput()
    process.close()
    return ManagedProcessResult(termination: termination, timedOut: timedOut)
  }
}
