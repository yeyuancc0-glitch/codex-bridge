import Foundation

public enum DirectProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case killed(Int32)
  case notStarted
}

public enum DirectProcessError: Error, Equatable, Sendable {
  case invalidArgument
  case processLaunchFailed(Int32)
  case stdinUnavailable
}

public final class DirectProcessLifetime: @unchecked Sendable {
  public var pid: Int32 { process.processIdentifier }
  private let process: Process
  private let output: DirectCommandOutputCollector
  private let inputPipe: Pipe?
  private let lock = NSLock()
  private var _termination: DirectProcessTermination?

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String]?,
    usePTY: Bool,
    output: DirectCommandOutputCollector
  ) throws {
    guard let executable = argv.first, !executable.isEmpty else {
      throw DirectProcessError.invalidArgument
    }
    guard argv.count <= 128 else { throw DirectProcessError.invalidArgument }
    self.output = output
    self.process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(argv.dropFirst())
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    var env = environment ?? [:]
    env["PATH"] = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = env

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    if usePTY {
      throw DirectProcessError.invalidArgument
    }
    let inputPipe = Pipe()
    process.standardInput = inputPipe
    self.inputPipe = inputPipe

    process.terminationHandler = { [weak self] _ in
      self?.captureTermination()
    }

    do {
      try process.run()
    } catch {
      throw DirectProcessError.processLaunchFailed(0)
    }
    _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty {
        self?.output.append(data)
      }
    }
  }

  private func captureTermination() {
    lock.lock()
    defer { lock.unlock() }
    guard _termination == nil else { return }
    switch process.terminationReason {
    case .exit:
      _termination = .exited(process.terminationStatus)
    case .uncaughtSignal:
      _termination = .killed(process.terminationStatus)
    @unknown default:
      _termination = .killed(process.terminationStatus)
    }
  }

  public func writeStdin(_ data: Data) throws {
    guard let inputPipe else { throw DirectProcessError.stdinUnavailable }
    do {
      try inputPipe.fileHandleForWriting.write(contentsOf: data)
    } catch {
      throw DirectProcessError.stdinUnavailable
    }
  }

  public func terminateGroup() {
    _ = Darwin.kill(-pid, SIGTERM)
  }

  public func killGroup() {
    if isRunning {
      _ = Darwin.kill(-pid, SIGKILL)
    }
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _termination == nil
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200)) -> DirectProcessTermination?
  {
    lock.lock()
    if let termination = _termination {
      lock.unlock()
      return termination
    }
    lock.unlock()
    let deadline = ContinuousClock.now.advanced(by: gracePeriod)
    while ContinuousClock.now < deadline {
      lock.lock()
      let termination = _termination
      lock.unlock()
      if let termination {
        return termination
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
  }

  public func waitForExit(timeout: Duration) -> DirectProcessTermination? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let termination = reapIfExited() {
        return termination
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return reapIfExited()
  }

  public func pollOutput() {
    // Process delivers output incrementally through the readability handler.
  }

  public func drainRemainingOutput() {
    lock.lock()
    let termination = _termination
    lock.unlock()
    guard termination != nil else { return }
    guard let handle = (process.standardOutput as? Pipe)?.fileHandleForReading else {
      return
    }
    handle.readabilityHandler = nil
    var buffer = Data()
    var chunk = Data(capacity: 16 * 1_024)
    while true {
      chunk = handle.readData(ofLength: 16 * 1_024)
      if chunk.isEmpty { break }
      buffer.append(chunk)
    }
    if !buffer.isEmpty {
      output.append(buffer)
    }
  }

  public func close() {
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    inputPipe?.fileHandleForWriting.closeFile()
  }
}
