import Darwin
import Foundation

public struct DirectProcessIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let startTimeMicros: Int64
  public let processGroupID: Int32

  public init(pid: Int32, startTimeMicros: Int64, processGroupID: Int32) {
    self.pid = pid
    self.startTimeMicros = startTimeMicros
    self.processGroupID = processGroupID
  }
}

public enum DirectProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case killed(Int32)
  case notStarted
}

public enum DirectProcessError: Error, Equatable, Sendable {
  case invalidArgument
  case processLaunchFailed(Int32)
  case stdinUnavailable
  case sandboxUnavailable
}

public final class DirectProcessLifetime: @unchecked Sendable {
  public let pid: Int32
  private let output: DirectCommandOutputCollector
  private let outputHandle: FileHandle
  private let inputHandle: FileHandle
  private let lock = NSLock()
  private let inputLock = NSLock()
  private var _termination: DirectProcessTermination?
  private var _identity: DirectProcessIdentity?
  private var inputClosed = false

  public var identity: DirectProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    return _identity
  }

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String]?,
    usePTY: Bool,
    output: DirectCommandOutputCollector,
    denyNetwork: Bool = false
  ) throws {
    guard let executable = argv.first, !executable.isEmpty else {
      throw DirectProcessError.invalidArgument
    }
    guard argv.count <= 128 else { throw DirectProcessError.invalidArgument }
    self.output = output
    let launchArgv: [String]
    if denyNetwork {
      guard Self.sandboxExecAvailable else { throw DirectProcessError.sandboxUnavailable }
      launchArgv = [Self.sandboxExecPath, "-p", Self.denyNetworkProfile, "--"] + argv
    } else {
      launchArgv = argv
    }
    var env = environment ?? [:]
    env["PATH"] = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let outputPipe = Pipe()
    if usePTY {
      throw DirectProcessError.invalidArgument
    }
    let inputPipe = Pipe()
    let processID: pid_t
    do {
      processID = try Self.spawn(
        argv: launchArgv,
        workingDirectory: workingDirectory,
        environment: env,
        standardInput: inputPipe.fileHandleForReading.fileDescriptor,
        standardOutput: outputPipe.fileHandleForWriting.fileDescriptor
      )
    } catch {
      inputPipe.fileHandleForReading.closeFile()
      inputPipe.fileHandleForWriting.closeFile()
      outputPipe.fileHandleForReading.closeFile()
      outputPipe.fileHandleForWriting.closeFile()
      throw error
    }
    inputPipe.fileHandleForReading.closeFile()
    outputPipe.fileHandleForWriting.closeFile()
    pid = processID
    inputHandle = inputPipe.fileHandleForWriting
    outputHandle = outputPipe.fileHandleForReading
    _identity = Self.identity(of: processID)

    outputHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty {
        self?.output.append(data)
      }
    }
  }

  public func writeStdin(_ data: Data) throws {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { throw DirectProcessError.stdinUnavailable }
    do {
      try inputHandle.write(contentsOf: data)
    } catch {
      throw DirectProcessError.stdinUnavailable
    }
  }

  public func closeStdin() {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard !inputClosed else { return }
    inputClosed = true
    inputHandle.closeFile()
  }

  public func terminateGroup() {
    guard isRunning else { return }
    _ = Darwin.kill(-pid, SIGTERM)
  }

  public func killGroup() {
    if isRunning { _ = Darwin.kill(-pid, SIGKILL) }
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    _ = reapIfExitedLocked()
    return _termination == nil
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200)) -> DirectProcessTermination?
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

  public func terminateAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> DirectProcessTermination? {
    terminateGroup()
    if let termination = waitForExit(timeout: gracePeriod) {
      return termination
    }
    killGroup()
    return waitForExit(timeout: killWait)
  }

  public func pollOutput() {
  }

  public func drainRemainingOutput() {
    lock.lock()
    let termination = _termination
    lock.unlock()
    guard termination != nil else { return }
    outputHandle.readabilityHandler = nil
    var buffer = Data()
    var chunk = Data(capacity: 16 * 1_024)
    while true {
      chunk = outputHandle.readData(ofLength: 16 * 1_024)
      if chunk.isEmpty { break }
      buffer.append(chunk)
    }
    if !buffer.isEmpty {
      output.append(buffer)
    }
  }

  public func close() {
    outputHandle.readabilityHandler = nil
    outputHandle.closeFile()
    closeStdin()
  }

  private func reapIfExitedLocked() -> DirectProcessTermination? {
    if let termination = _termination { return termination }
    var status: Int32 = 0
    let result = Darwin.waitpid(pid, &status, WNOHANG)
    guard result == pid else { return nil }
    let signal = status & 0x7F
    let termination: DirectProcessTermination =
      signal == 0
      ? .exited((status >> 8) & 0xFF)
      : .killed(signal)
    _termination = termination
    return termination
  }

  private static func spawn(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32
  ) throws -> pid_t {
    guard let executable = argv.first,
      executable.hasPrefix("/"),
      argv.allSatisfy({ !$0.contains("\0") }),
      environment.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") })
    else { throw DirectProcessError.invalidArgument }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw DirectProcessError.processLaunchFailed(Int32(errno))
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw DirectProcessError.processLaunchFailed(Int32(errno))
    }
    defer {
      posix_spawnattr_destroy(&attributes)
    }
    guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, standardOutput, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addclose(&actions, standardInput) == 0,
      posix_spawn_file_actions_addclose(&actions, standardOutput) == 0
    else { throw DirectProcessError.processLaunchFailed(Int32(errno)) }
    if let workingDirectory {
      let result: Int32
      if #available(macOS 26.0, *) {
        result = posix_spawn_file_actions_addchdir(&actions, workingDirectory)
      } else {
        result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
      }
      guard result == 0 else { throw DirectProcessError.processLaunchFailed(result) }
    }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { throw DirectProcessError.processLaunchFailed(Int32(errno)) }

    let environmentEntries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    return try withCStringArray(argv) { argvPointer in
      try withCStringArray(environmentEntries) { environmentPointer in
        var processID: pid_t = 0
        let result = posix_spawn(
          &processID,
          executable,
          &actions,
          &attributes,
          argvPointer,
          environmentPointer
        )
        guard result == 0, processID > 1 else {
          throw DirectProcessError.processLaunchFailed(result)
        }
        return processID
      }
    }
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    var storage = strings.map { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    storage.append(nil)
    return try storage.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }

  public static func identity(of processID: Int32) -> DirectProcessIdentity? {
    guard processID > 1,
      Darwin.getpgid(processID) == processID,
      let startTimeMicros = startTimeMicros(processID)
    else { return nil }
    return DirectProcessIdentity(
      pid: processID,
      startTimeMicros: startTimeMicros,
      processGroupID: processID
    )
  }

  public static func matchesCurrentProcess(_ identity: DirectProcessIdentity) -> Bool {
    guard let current = Self.identity(of: identity.pid) else { return false }
    return current == identity
  }

  private static func startTimeMicros(_ processID: Int32) -> Int64? {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        pointer,
        expectedSize
      )
    }
    guard result == expectedSize else { return nil }
    let seconds = Int64(info.pbi_start_tvsec)
    let micros = Int64(info.pbi_start_tvusec)
    let (base, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
    guard !overflow else { return nil }
    let (total, additionOverflow) = base.addingReportingOverflow(micros)
    return additionOverflow ? nil : total
  }

  private static let sandboxExecPath = "/usr/bin/sandbox-exec"
  private static let sandboxExecAvailable = FileManager.default.isExecutableFile(
    atPath: sandboxExecPath)

  private static let denyNetworkProfile = "(version 1)(allow default)(deny network*)"
}
