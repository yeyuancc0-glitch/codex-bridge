import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public final class ManagedStdioProcess: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (Data) -> Void

  public let pid: Int32
  private let standardOutputHandle: FileHandle
  private let standardErrorHandle: FileHandle?
  private let standardInputHandle: FileHandle
  private let standardOutputSink: OutputHandler
  private let standardErrorSink: OutputHandler
  private let lock = NSLock()
  private let inputLock = NSLock()
  private let outputLock = NSLock()
  private var terminationStorage: ManagedProcessTermination?
  private var identityStorage: ManagedProcessIdentity?
  private var inputClosed = false
  private var handlesClosed = false

  public var identity: ManagedProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    return identityStorage
  }

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    mergeStandardError: Bool,
    onStandardOutput: @escaping OutputHandler,
    onStandardError: @escaping OutputHandler = { _ in }
  ) throws {
    guard let executable = argv.first,
      executable.hasPrefix("/"),
      argv.count <= 128,
      argv.allSatisfy({ !$0.contains("\0") }),
      environment.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }),
      workingDirectory.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true
    else {
      throw ManagedProcessError.invalidArgument
    }

    standardOutputSink = onStandardOutput
    standardErrorSink = onStandardError

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = mergeStandardError ? nil : Pipe()
    let processID: pid_t
    do {
      processID = try Self.spawn(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: inputPipe.fileHandleForReading.fileDescriptor,
        standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
        standardError: mergeStandardError
          ? outputPipe.fileHandleForWriting.fileDescriptor
          : errorPipe!.fileHandleForWriting.fileDescriptor
      )
    } catch {
      inputPipe.fileHandleForReading.closeFile()
      inputPipe.fileHandleForWriting.closeFile()
      outputPipe.fileHandleForReading.closeFile()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe?.fileHandleForReading.closeFile()
      errorPipe?.fileHandleForWriting.closeFile()
      throw error
    }

    inputPipe.fileHandleForReading.closeFile()
    outputPipe.fileHandleForWriting.closeFile()
    errorPipe?.fileHandleForWriting.closeFile()

    pid = processID
    standardInputHandle = inputPipe.fileHandleForWriting
    standardOutputHandle = outputPipe.fileHandleForReading
    standardErrorHandle = errorPipe?.fileHandleForReading
    identityStorage = Self.identity(of: processID)

    standardOutputHandle.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      consumeAvailableData(handle, sink: standardOutputSink)
    }
    standardErrorHandle?.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      consumeAvailableData(handle, sink: standardErrorSink)
    }
  }

  public func writeStdin(_ data: Data) throws {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { throw ManagedProcessError.stdinUnavailable }
    do {
      try standardInputHandle.write(contentsOf: data)
    } catch {
      throw ManagedProcessError.stdinUnavailable
    }
  }

  public func writeStdin(_ data: Data, timeout: Duration) throws {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { throw ManagedProcessError.stdinUnavailable }

    let descriptor = standardInputHandle.fileDescriptor
    let previousFlags = fcntl(descriptor, F_GETFL)
    guard previousFlags >= 0,
      fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0
    else {
      throw ManagedProcessError.stdinUnavailable
    }
    defer { _ = fcntl(descriptor, F_SETFL, previousFlags) }

    let deadline = ContinuousClock.now.advanced(by: timeout)
    do {
      try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
          let written = systemWrite(
            descriptor,
            baseAddress.advanced(by: offset),
            buffer.count - offset
          )
          if written > 0 {
            offset += written
            continue
          }
          if written == -1, errno == EINTR { continue }
          guard written == -1, errno == EAGAIN || errno == EWOULDBLOCK,
            ContinuousClock.now < deadline
          else {
            throw ManagedProcessError.stdinUnavailable
          }
          Thread.sleep(forTimeInterval: 0.01)
        }
      }
    } catch {
      throw ManagedProcessError.stdinUnavailable
    }
  }

  public func closeStdin() {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { return }
    inputClosed = true
    standardInputHandle.closeFile()
  }

  public func terminateGroup() {
    guard isRunning else { return }
    _ = systemKill(-pid, SIGTERM)
  }

  public func interruptGroup() {
    guard isRunning else { return }
    _ = systemKill(-pid, SIGINT)
  }

  public func killGroup() {
    if isRunning { _ = systemKill(-pid, SIGKILL) }
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    _ = reapIfExitedLocked()
    return terminationStorage == nil
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200))
    -> ManagedProcessTermination?
  {
    lock.lock()
    if let termination = reapIfExitedLocked() {
      lock.unlock()
      return termination
    }
    lock.unlock()

    let deadline = ContinuousClock.now.advanced(by: gracePeriod)
    while ContinuousClock.now < deadline {
      lock.lock()
      let termination = reapIfExitedLocked()
      lock.unlock()
      if let termination { return termination }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
  }

  public func waitForExit(timeout: Duration) -> ManagedProcessTermination? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let termination = reapIfExited() { return termination }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return reapIfExited()
  }

  public func terminateAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> ManagedProcessTermination? {
    terminateGroup()
    if let termination = waitForExit(timeout: gracePeriod) { return termination }
    killGroup()
    return waitForExit(timeout: killWait)
  }

  public func drainRemainingOutput() {
    lock.lock()
    let hasTerminated = terminationStorage != nil
    lock.unlock()
    guard hasTerminated else { return }

    outputLock.lock()
    defer { outputLock.unlock() }
    guard !handlesClosed else { return }
    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    drain(standardOutputHandle, sink: standardOutputSink)
    if let standardErrorHandle { drain(standardErrorHandle, sink: standardErrorSink) }
  }

  public func close() {
    outputLock.lock()
    guard !handlesClosed else {
      outputLock.unlock()
      closeStdin()
      return
    }
    handlesClosed = true
    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    standardOutputHandle.closeFile()
    standardErrorHandle?.closeFile()
    outputLock.unlock()
    closeStdin()
  }

  private func consumeAvailableData(_ handle: FileHandle, sink: OutputHandler) {
    outputLock.lock()
    defer { outputLock.unlock() }
    guard !handlesClosed else { return }
    let data = handle.availableData
    if !data.isEmpty { sink(data) }
  }

  private func drain(_ handle: FileHandle, sink: OutputHandler) {
    while true {
      let data = handle.readData(ofLength: 16 * 1_024)
      if data.isEmpty { return }
      sink(data)
    }
  }

  private func reapIfExitedLocked() -> ManagedProcessTermination? {
    if let terminationStorage { return terminationStorage }
    var status: Int32 = 0
    let result = systemWaitPID(pid, &status, WNOHANG)
    guard result == pid else { return nil }
    let signal = status & 0x7F
    let termination: ManagedProcessTermination =
      signal == 0 ? .exited((status >> 8) & 0xFF) : .killed(signal)
    terminationStorage = termination
    return termination
  }
}
#if canImport(Darwin)
  private let systemKill = Darwin.kill
  private let systemWaitPID = Darwin.waitpid
  private let systemWrite = Darwin.write
#else
  private let systemKill = Glibc.kill
  private let systemWaitPID = Glibc.waitpid
  private let systemWrite = Glibc.write
#endif
