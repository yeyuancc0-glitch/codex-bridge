import Darwin
import Foundation

struct TunnelChildExit: Equatable, Sendable {
  let code: Int32
}

final class TunnelSpawnedProcess: @unchecked Sendable {
  let pid: pid_t
  let stdout: RedactedOutputBuffer
  let stderr: RedactedOutputBuffer
  private let stdoutReader: DescriptorReader
  private let stderrReader: DescriptorReader
  private let lock = NSLock()
  private var exit: TunnelChildExit?
  private var terminationClaimed = false

  init(
    pid: pid_t,
    stdout: RedactedOutputBuffer,
    stderr: RedactedOutputBuffer,
    stdoutDescriptor: Int32,
    stderrDescriptor: Int32
  ) {
    self.pid = pid
    self.stdout = stdout
    self.stderr = stderr
    stdoutReader = DescriptorReader(descriptor: stdoutDescriptor, buffer: stdout)
    stderrReader = DescriptorReader(descriptor: stderrDescriptor, buffer: stderr)
    stdoutReader.start()
    stderrReader.start()
  }

  deinit {
    lock.withLock {
      guard resolveExitLocked() == nil else { return }
      _ = Darwin.kill(pid, SIGKILL)
      var status: Int32 = 0
      var result: pid_t = -1
      repeat {
        result = waitpid(pid, &status, 0)
      } while result < 0 && errno == EINTR
      guard result == pid else { return }
      exit = TunnelChildExit(code: Self.exitCode(status))
      stdoutReader.finish()
      stderrReader.finish()
    }
  }

  func pollExit() -> TunnelChildExit? {
    lock.withLock {
      resolveExitLocked()
    }
  }

  func beginTermination() -> Bool {
    lock.withLock {
      guard resolveExitLocked() == nil, !terminationClaimed else { return false }
      terminationClaimed = true
      return Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH
    }
  }

  func escalateTermination() {
    lock.withLock {
      guard resolveExitLocked() == nil else { return }
      _ = Darwin.kill(pid, SIGKILL)
    }
  }

  private func resolveExitLocked() -> TunnelChildExit? {
    if let exit { return exit }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result < 0, errno == ECHILD {
      let resolved = TunnelChildExit(code: 255)
      exit = resolved
      stdoutReader.finish()
      stderrReader.finish()
      return resolved
    }
    guard result == pid else { return nil }
    let resolved = TunnelChildExit(code: Self.exitCode(status))
    exit = resolved
    stdoutReader.finish()
    stderrReader.finish()
    return resolved
  }

  private static func exitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    if signal != 0x7f { return 128 + signal }
    return status
  }
}

struct TunnelProcessLauncher: Sendable {
  func spawn(
    verifiedHelper: TunnelVerifiedHelper,
    helperVerifier: TunnelHelperVerifier,
    arguments: [String],
    runtimeKey: Data,
    localMCPHeaderSecret: Data,
    runtimeDirectory: URL,
    sensitiveValues: [String],
    outputLimit: Int
  ) throws -> TunnelSpawnedProcess {
    let secretPipe = try DescriptorPipe()
    let urlPipe = try DescriptorPipe()
    let stdoutPipe = try DescriptorPipe()
    let stderrPipe = try DescriptorPipe()
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw TunnelManagerError.launchFailed
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      throw TunnelManagerError.launchFailed
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    try configureActions(
      &actions,
      secretRead: secretPipe.readDescriptor,
      urlRead: urlPipe.readDescriptor,
      stdoutWrite: stdoutPipe.writeDescriptor,
      stderrWrite: stderrPipe.writeDescriptor
    )
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGTERM)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGHUP)
    sigaddset(&defaults, SIGQUIT)
    var mask = sigset_t()
    sigemptyset(&mask)
    guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
      posix_spawnattr_setsigmask(&attributes, &mask) == 0
    else {
      throw TunnelManagerError.launchFailed
    }
    let flags = Int16(
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        | POSIX_SPAWN_START_SUSPENDED
    )
    guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
      throw TunnelManagerError.launchFailed
    }
    var pid: pid_t = 0
    let status = spawn(
      &pid,
      executable: verifiedHelper.executable.path,
      arguments: [verifiedHelper.executable.path] + arguments,
      actions: &actions,
      attributes: &attributes,
      runtimeDirectory: runtimeDirectory
    )
    guard status == 0 else { throw TunnelManagerError.launchFailed }
    secretPipe.closeRead()
    urlPipe.closeRead()
    stdoutPipe.closeWrite()
    stderrPipe.closeWrite()
    do {
      try helperVerifier.verifyRunning(
        processID: pid,
        expectedIdentity: verifiedHelper.codeIdentity
      )
      guard Darwin.kill(pid, SIGCONT) == 0 else {
        throw TunnelManagerError.launchFailed
      }
      try writeAndClose(runtimeKey, to: secretPipe)
      try writeAndClose(localMCPHeaderSecret, to: urlPipe)
    } catch {
      secretPipe.closeWrite()
      urlPipe.closeWrite()
      killAndReap(pid)
      throw error
    }
    let stdout = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
    let stderr = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
    return TunnelSpawnedProcess(
      pid: pid,
      stdout: stdout,
      stderr: stderr,
      stdoutDescriptor: stdoutPipe.takeRead(),
      stderrDescriptor: stderrPipe.takeRead()
    )
  }

  private func configureActions(
    _ actions: inout posix_spawn_file_actions_t?,
    secretRead: Int32,
    urlRead: Int32,
    stdoutWrite: Int32,
    stderrWrite: Int32
  ) throws {
    guard
      posix_spawn_file_actions_addopen(
        &actions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ) == 0
    else {
      throw TunnelManagerError.launchFailed
    }
    let mappings: [(Int32, Int32)] = [
      (secretRead, 3), (urlRead, 4), (stdoutWrite, STDOUT_FILENO),
      (stderrWrite, STDERR_FILENO),
    ]
    for mapping in mappings {
      guard posix_spawn_file_actions_adddup2(&actions, mapping.0, mapping.1) == 0 else {
        throw TunnelManagerError.launchFailed
      }
    }
  }

  private func spawn(
    _ pid: inout pid_t,
    executable: String,
    arguments: [String],
    actions: inout posix_spawn_file_actions_t?,
    attributes: inout posix_spawnattr_t?,
    runtimeDirectory: URL
  ) -> Int32 {
    let ownedArguments = arguments.compactMap { strdup($0) }
    guard ownedArguments.count == arguments.count else { return ENOMEM }
    defer {
      for argument in ownedArguments { free(argument) }
    }
    var argv = ownedArguments + [nil]
    let runtimePath = runtimeDirectory.standardizedFileURL.path
    let environmentStrings: [String] = [
      "TMPDIR=\(runtimePath)",
      "CODEX_HOME=\(runtimePath)/codex-home",
    ]
    let ownedEnvironment: [UnsafeMutablePointer<CChar>] = environmentStrings.compactMap {
      strdup($0)
    }
    guard ownedEnvironment.count == environmentStrings.count else { return ENOMEM }
    defer {
      for value in ownedEnvironment { free(value) }
    }
    var environment: [UnsafeMutablePointer<CChar>?] = ownedEnvironment + [nil]
    return argv.withUnsafeMutableBufferPointer { argvBuffer in
      environment.withUnsafeMutableBufferPointer { environmentBuffer in
        posix_spawn(
          &pid,
          executable,
          &actions,
          &attributes,
          argvBuffer.baseAddress,
          environmentBuffer.baseAddress
        )
      }
    }
  }

  private func writeAndClose(_ data: Data, to pipe: DescriptorPipe) throws {
    let descriptor = pipe.writeDescriptor
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          descriptor, baseAddress.advanced(by: written), bytes.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw TunnelManagerError.launchFailed }
        written += count
      }
    }
    pipe.closeWrite()
  }

  private func killAndReap(_ pid: pid_t) {
    _ = Darwin.kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
  }
}

private final class DescriptorPipe: @unchecked Sendable {
  private let lock = NSLock()
  private var readValue: Int32
  private var writeValue: Int32

  init() throws {
    var descriptors: [Int32] = [0, 0]
    let status = descriptors.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) }
    guard status == 0 else { throw TunnelManagerError.launchFailed }
    readValue = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 10)
    writeValue = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 10)
    Darwin.close(descriptors[0])
    Darwin.close(descriptors[1])
    guard readValue >= 10, writeValue >= 10 else {
      closeRead()
      closeWrite()
      throw TunnelManagerError.launchFailed
    }
  }

  deinit {
    closeRead()
    closeWrite()
  }

  var readDescriptor: Int32 { lock.withLock { readValue } }
  var writeDescriptor: Int32 { lock.withLock { writeValue } }

  func takeRead() -> Int32 {
    lock.withLock {
      let descriptor = readValue
      readValue = -1
      return descriptor
    }
  }

  func closeRead() {
    lock.withLock {
      guard readValue >= 0 else { return }
      Darwin.close(readValue)
      readValue = -1
    }
  }

  func closeWrite() {
    lock.withLock {
      guard writeValue >= 0 else { return }
      Darwin.close(writeValue)
      writeValue = -1
    }
  }
}

private final class DescriptorReader: @unchecked Sendable {
  private let fileHandle: FileHandle
  private let buffer: RedactedOutputBuffer
  private let lock = NSLock()
  private var finished = false

  init(descriptor: Int32, buffer: RedactedOutputBuffer) {
    fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    self.buffer = buffer
  }

  func start() {
    fileHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        self?.finish()
        return
      }
      self?.buffer.append(data)
    }
  }

  func finish() {
    lock.withLock {
      guard !finished else { return }
      finished = true
      fileHandle.readabilityHandler = nil
      buffer.append(fileHandle.readDataToEndOfFile())
      buffer.finish()
      try? fileHandle.close()
    }
  }
}
