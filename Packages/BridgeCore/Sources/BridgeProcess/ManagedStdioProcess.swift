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

    standardOutputHandle.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty { onStandardOutput(data) }
    }
    standardErrorHandle?.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty { onStandardError(data) }
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

    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    drain(standardOutputHandle, sink: standardOutputSink)
    if let standardErrorHandle { drain(standardErrorHandle, sink: standardErrorSink) }
  }

  public func close() {
    lock.lock()
    guard !handlesClosed else {
      lock.unlock()
      return
    }
    handlesClosed = true
    lock.unlock()

    standardOutputHandle.readabilityHandler = nil
    standardErrorHandle?.readabilityHandler = nil
    standardOutputHandle.closeFile()
    standardErrorHandle?.closeFile()
    closeStdin()
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

  public static func identity(of processID: Int32) -> ManagedProcessIdentity? {
    guard processID > 1,
      systemGetPGID(processID) == processID,
      let startTimeMicros = startTimeMicros(processID)
    else { return nil }
    return ManagedProcessIdentity(
      pid: processID,
      startTimeMicros: startTimeMicros,
      processGroupID: processID
    )
  }

  public static func matchesCurrentProcess(_ identity: ManagedProcessIdentity) -> Bool {
    Self.identity(of: identity.pid) == identity
  }
}

extension ManagedStdioProcess {
  fileprivate static func spawn(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32,
    standardError: Int32
  ) throws -> pid_t {
    #if canImport(Darwin)
      return try spawnDarwin(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
    #else
      return try spawnGlibc(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
    #endif
  }

  #if canImport(Darwin)
    fileprivate static func spawnDarwin(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws -> pid_t {
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawnattr_destroy(&attributes) }

      try configureDarwinActions(
        &actions,
        workingDirectory: workingDirectory,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
      let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      return try performSpawn(
        executable: argv[0],
        argv: argv,
        environment: environment,
        actions: &actions,
        attributes: &attributes
      )
    }

    fileprivate static func configureDarwinActions(
      _ actions: inout posix_spawn_file_actions_t?,
      workingDirectory: String?,
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws {
      guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, standardInput) == 0,
        posix_spawn_file_actions_addclose(&actions, standardOutput) == 0,
        standardError == standardOutput
          || posix_spawn_file_actions_addclose(&actions, standardError) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      if let workingDirectory {
        let result: Int32
        if #available(macOS 26.0, *) {
          result = posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        } else {
          result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }
        guard result == 0 else { throw ManagedProcessError.processLaunchFailed(result) }
      }
    }

    fileprivate static func performSpawn(
      executable: String,
      argv: [String],
      environment: [String: String],
      actions: inout posix_spawn_file_actions_t?,
      attributes: inout posix_spawnattr_t?
    ) throws -> pid_t {
      let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      return try withCStringArray(argv) { argvPointer in
        try withCStringArray(entries) { environmentPointer in
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
            throw ManagedProcessError.processLaunchFailed(result)
          }
          return processID
        }
      }
    }
  #else
    fileprivate static func spawnGlibc(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws -> pid_t {
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawnattr_destroy(&attributes) }

      guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, standardInput) == 0,
        posix_spawn_file_actions_addclose(&actions, standardOutput) == 0,
        standardError == standardOutput
          || posix_spawn_file_actions_addclose(&actions, standardError) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      if let workingDirectory {
        let result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        guard result == 0 else { throw ManagedProcessError.processLaunchFailed(result) }
      }
      let flags = Int16(POSIX_SPAWN_SETPGROUP)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }

      let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      return try withCStringArray(argv) { argvPointer in
        try withCStringArray(entries) { environmentPointer in
          var processID: pid_t = 0
          let result = posix_spawn(
            &processID,
            argv[0],
            &actions,
            &attributes,
            argvPointer,
            environmentPointer
          )
          guard result == 0, processID > 1 else {
            throw ManagedProcessError.processLaunchFailed(result)
          }
          return processID
        }
      }
    }
  #endif

  fileprivate static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    var storage = strings.map { strdup($0) }
    defer { for pointer in storage { free(pointer) } }
    storage.append(nil)
    return try storage.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }

  fileprivate static func startTimeMicros(_ processID: Int32) -> Int64? {
    #if canImport(Darwin)
      var info = proc_bsdinfo()
      let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
      }
      guard result == expectedSize else { return nil }
      let (base, overflow) = Int64(info.pbi_start_tvsec).multipliedReportingOverflow(by: 1_000_000)
      guard !overflow else { return nil }
      let (total, additionOverflow) = base.addingReportingOverflow(Int64(info.pbi_start_tvusec))
      return additionOverflow ? nil : total
    #else
      guard let data = FileManager.default.contents(atPath: "/proc/\(processID)/stat"),
        let stat = String(data: data, encoding: .utf8),
        let close = stat.lastIndex(of: ")")
      else { return nil }
      let fields = stat[stat.index(after: close)...].split(separator: " ")
      guard fields.count > 19, let ticks = Int64(fields[19]) else { return nil }
      let ticksPerSecond = Int64(sysconf(Int32(_SC_CLK_TCK)))
      guard ticksPerSecond > 0 else { return nil }
      return ticks * 1_000_000 / ticksPerSecond
    #endif
  }
}

#if canImport(Darwin)
  private let systemKill = Darwin.kill
  private let systemWaitPID = Darwin.waitpid
  private let systemGetPGID = Darwin.getpgid
#else
  private let systemKill = Glibc.kill
  private let systemWaitPID = Glibc.waitpid
  private let systemGetPGID = Glibc.getpgid
#endif

