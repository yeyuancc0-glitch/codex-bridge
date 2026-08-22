import BridgeSecurity
import Darwin
import Foundation

@_silgen_name("posix_spawn_file_actions_addfchdir_np")
private func verificationSpawnFileActionsAddFchdir(
  _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
  _ descriptor: Int32
) -> Int32

final class OpenedVerificationDirectory: @unchecked Sendable {
  let canonicalPath: String
  let descriptor: Int32
  private let identity: FileSystemIdentity

  init(root: RegisteredRoot) throws {
    var metadata = stat()
    let opened = Darwin.open(root.canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0, fstat(opened, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR
    else {
      if opened >= 0 { Darwin.close(opened) }
      throw BoundedVerificationProcessError.invalidWorkingDirectory
    }
    let openedIdentity = FileSystemIdentity(
      posixDevice: UInt64(metadata.st_dev),
      posixInode: UInt64(metadata.st_ino)
    )
    guard openedIdentity == root.identity else {
      Darwin.close(opened)
      throw BoundedVerificationProcessError.invalidWorkingDirectory
    }
    canonicalPath = root.canonicalPath
    descriptor = opened
    identity = openedIdentity
  }

  deinit {
    Darwin.close(descriptor)
  }

  func validatePathIdentity() throws {
    var metadata = stat()
    let status = canonicalPath.withCString { Darwin.lstat($0, &metadata) }
    let current = FileSystemIdentity(
      posixDevice: UInt64(metadata.st_dev),
      posixInode: UInt64(metadata.st_ino)
    )
    guard status == 0, metadata.st_mode & S_IFMT == S_IFDIR, current == identity else {
      throw BoundedVerificationProcessError.invalidWorkingDirectory
    }
  }
}

enum BoundedVerificationProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case timedOut
  case cancelled
  case outputLimit
}

struct BoundedVerificationProcessOutcome: Equatable, Sendable {
  let termination: BoundedVerificationProcessTermination
  let standardOutput: Data
  let standardError: Data
  let standardOutputTruncated: Bool
  let standardErrorTruncated: Bool
}

struct BoundedVerificationProcessConfiguration: Sendable {
  let executableURL: URL
  let arguments: [String]
  let workingDirectory: OpenedVerificationDirectory
  let environment: [String]
  let timeout: Duration
  let terminationGracePeriod: Duration
  let maximumStandardOutputBytes: Int
  let maximumStandardErrorBytes: Int
}

enum BoundedVerificationProcessError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidWorkingDirectory
  case launchFailed
  case childAlreadyReaped
  case waitFailed
}

struct BoundedVerificationProcessRunner: Sendable {
  func run(_ configuration: BoundedVerificationProcessConfiguration) async throws
    -> BoundedVerificationProcessOutcome
  {
    try Self.validate(configuration)
    try configuration.workingDirectory.validatePathIdentity()
    var child = try spawn(configuration)
    do {
      return try await monitor(&child, configuration: configuration)
    } catch BoundedVerificationProcessError.childAlreadyReaped {
      child.drainAfterExit()
      throw BoundedVerificationProcessError.waitFailed
    } catch {
      await terminateAndReap(&child, gracePeriod: configuration.terminationGracePeriod)
      throw error
    }
  }

  private func monitor(
    _ child: inout VerificationChildProcess,
    configuration: BoundedVerificationProcessConfiguration
  ) async throws -> BoundedVerificationProcessOutcome {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: configuration.timeout)
    while true {
      child.drainOutput()
      if child.outputExceededLimit {
        await terminateAndReap(&child, gracePeriod: configuration.terminationGracePeriod)
        return child.outcome(termination: .outputLimit)
      }
      if try child.hasExited() {
        terminateRemainingProcessGroupBeforeReap(child.processGroupID)
        let code = try child.reapExit()
        child.drainAfterExit()
        return child.outcome(termination: .exited(code))
      }
      if Task.isCancelled {
        await terminateAndReap(&child, gracePeriod: configuration.terminationGracePeriod)
        return child.outcome(termination: .cancelled)
      }
      if clock.now >= deadline {
        await terminateAndReap(&child, gracePeriod: configuration.terminationGracePeriod)
        return child.outcome(termination: .timedOut)
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func terminateAndReap(
    _ child: inout VerificationChildProcess,
    gracePeriod: Duration
  ) async {
    _ = signalProcessGroup(child.processGroupID, signal: SIGTERM)
    let deadline = ContinuousClock().now.advanced(by: gracePeriod)
    while ContinuousClock().now < deadline {
      child.drainOutput()
      await pause()
    }
    _ = signalProcessGroup(child.processGroupID, signal: SIGKILL)
    _ = try? child.reapExit()
    child.drainAfterExit()
  }

  private func terminateRemainingProcessGroupBeforeReap(_ processGroupID: pid_t) {
    _ = signalProcessGroup(processGroupID, signal: SIGTERM)
    _ = signalProcessGroup(processGroupID, signal: SIGKILL)
  }

  private func pause(for duration: Duration = .milliseconds(5)) async {
    await Task.detached {
      try? await Task.sleep(for: duration)
    }.value
  }

  @discardableResult
  private func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) -> Bool {
    guard processGroupID > 1 else { return false }
    return Darwin.kill(-processGroupID, signal) == 0
  }

  private func spawn(_ configuration: BoundedVerificationProcessConfiguration) throws
    -> VerificationChildProcess
  {
    var outputPipe = try VerificationDescriptorPipe()
    defer { outputPipe.closeBoth() }
    var errorPipe = try VerificationDescriptorPipe()
    defer { errorPipe.closeBoth() }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw BoundedVerificationProcessError.launchFailed
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      throw BoundedVerificationProcessError.launchFailed
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }

    try configureFileActions(
      &actions,
      currentDirectoryDescriptor: configuration.workingDirectory.descriptor,
      outputPipe: outputPipe,
      errorPipe: errorPipe
    )
    try configureSpawnAttributes(&attributes)
    var pid: pid_t = 0
    let status = spawn(
      pid: &pid,
      executable: configuration.executableURL.path,
      arguments: [configuration.executableURL.path] + configuration.arguments,
      environment: configuration.environment,
      actions: &actions,
      attributes: &attributes
    )
    guard status == 0 else { throw BoundedVerificationProcessError.launchFailed }
    outputPipe.closeWrite()
    errorPipe.closeWrite()
    return VerificationChildProcess(
      pid: pid,
      outputDescriptor: outputPipe.takeRead(),
      errorDescriptor: errorPipe.takeRead(),
      maximumStandardOutputBytes: configuration.maximumStandardOutputBytes,
      maximumStandardErrorBytes: configuration.maximumStandardErrorBytes
    )
  }

  private func configureFileActions(
    _ actions: inout posix_spawn_file_actions_t?,
    currentDirectoryDescriptor: Int32,
    outputPipe: VerificationDescriptorPipe,
    errorPipe: VerificationDescriptorPipe
  ) throws {
    guard
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, outputPipe.writeDescriptor, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, errorPipe.writeDescriptor, STDERR_FILENO) == 0,
      verificationSpawnFileActionsAddFchdir(&actions, currentDirectoryDescriptor) == 0
    else {
      throw BoundedVerificationProcessError.launchFailed
    }
  }

  private func configureSpawnAttributes(_ attributes: inout posix_spawnattr_t?) throws {
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
      sigaddset(&defaults, signal)
    }
    var mask = sigset_t()
    sigemptyset(&mask)
    let flags = Int16(
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        | POSIX_SPAWN_SETPGROUP
    )
    guard
      posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
      posix_spawnattr_setsigmask(&attributes, &mask) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawnattr_setflags(&attributes, flags) == 0
    else {
      throw BoundedVerificationProcessError.launchFailed
    }
  }

  private func spawn(
    pid: inout pid_t,
    executable: String,
    arguments: [String],
    environment: [String],
    actions: inout posix_spawn_file_actions_t?,
    attributes: inout posix_spawnattr_t?
  ) -> Int32 {
    let ownedArguments = arguments.compactMap { strdup($0) }
    guard ownedArguments.count == arguments.count else { return ENOMEM }
    defer {
      for argument in ownedArguments { free(argument) }
    }
    let ownedEnvironment = environment.compactMap { strdup($0) }
    guard ownedEnvironment.count == environment.count else { return ENOMEM }
    defer {
      for value in ownedEnvironment { free(value) }
    }

    var argv: [UnsafeMutablePointer<CChar>?] = ownedArguments + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = ownedEnvironment + [nil]
    return argv.withUnsafeMutableBufferPointer { argvBuffer in
      envp.withUnsafeMutableBufferPointer { environmentBuffer in
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

  private static func validate(_ configuration: BoundedVerificationProcessConfiguration) throws {
    let strings =
      [configuration.executableURL.path, configuration.workingDirectory.canonicalPath]
      + configuration.arguments + configuration.environment
    guard
      configuration.executableURL.isFileURL,
      configuration.executableURL.path.hasPrefix("/"),
      configuration.maximumStandardOutputBytes > 0,
      configuration.maximumStandardErrorBytes > 0,
      strings.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16 * 1_024 })
    else {
      throw BoundedVerificationProcessError.invalidConfiguration
    }
  }
}

private struct VerificationChildProcess {
  let pid: pid_t
  private var outputDescriptor: Int32
  private var errorDescriptor: Int32
  private var standardOutput: VerificationByteBuffer
  private var standardError: VerificationByteBuffer

  init(
    pid: pid_t,
    outputDescriptor: Int32,
    errorDescriptor: Int32,
    maximumStandardOutputBytes: Int,
    maximumStandardErrorBytes: Int
  ) {
    self.pid = pid
    self.outputDescriptor = outputDescriptor
    self.errorDescriptor = errorDescriptor
    standardOutput = VerificationByteBuffer(limit: maximumStandardOutputBytes)
    standardError = VerificationByteBuffer(limit: maximumStandardErrorBytes)
  }

  var processGroupID: pid_t { pid }

  var outputExceededLimit: Bool {
    standardOutput.isTruncated || standardError.isTruncated
  }

  mutating func drainOutput() {
    Self.drain(descriptor: &outputDescriptor, into: &standardOutput, maximumChunks: 16)
    Self.drain(descriptor: &errorDescriptor, into: &standardError, maximumChunks: 16)
  }

  mutating func drainAfterExit() {
    Self.drain(descriptor: &outputDescriptor, into: &standardOutput, maximumChunks: .max)
    Self.drain(descriptor: &errorDescriptor, into: &standardError, maximumChunks: .max)
    closeDescriptors()
  }

  func hasExited() throws -> Bool {
    var information = siginfo_t()
    var result: Int32 = -1
    repeat {
      result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
    } while result < 0 && errno == EINTR
    if result < 0, errno == ECHILD {
      throw BoundedVerificationProcessError.childAlreadyReaped
    }
    guard result == 0 else { throw BoundedVerificationProcessError.waitFailed }
    return information.si_pid == pid
  }

  func reapExit() throws -> Int32 {
    var status: Int32 = 0
    var result: pid_t = -1
    repeat {
      result = waitpid(pid, &status, 0)
    } while result < 0 && errno == EINTR
    if result < 0, errno == ECHILD {
      throw BoundedVerificationProcessError.childAlreadyReaped
    }
    guard result == pid else { throw BoundedVerificationProcessError.waitFailed }
    return Self.exitCode(status)
  }

  func outcome(
    termination: BoundedVerificationProcessTermination
  ) -> BoundedVerificationProcessOutcome {
    BoundedVerificationProcessOutcome(
      termination: termination,
      standardOutput: standardOutput.data,
      standardError: standardError.data,
      standardOutputTruncated: standardOutput.isTruncated,
      standardErrorTruncated: standardError.isTruncated
    )
  }

  private static func drain(
    descriptor: inout Int32,
    into buffer: inout VerificationByteBuffer,
    maximumChunks: Int
  ) {
    guard descriptor >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
    var chunks = 0
    while chunks < maximumChunks {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        buffer.append(Data(bytes.prefix(count)))
        chunks += 1
        continue
      }
      if count == 0 {
        Darwin.close(descriptor)
        descriptor = -1
        return
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }
      Darwin.close(descriptor)
      descriptor = -1
      return
    }
  }

  private mutating func closeDescriptors() {
    if outputDescriptor >= 0 { Darwin.close(outputDescriptor) }
    if errorDescriptor >= 0 { Darwin.close(errorDescriptor) }
    outputDescriptor = -1
    errorDescriptor = -1
  }

  private static func exitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    if signal != 0x7f { return 128 + signal }
    return status
  }
}

private struct VerificationByteBuffer {
  let limit: Int
  private(set) var data = Data()
  private(set) var isTruncated = false

  mutating func append(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    let remaining = limit - data.count
    guard remaining > 0 else {
      isTruncated = true
      return
    }
    data.append(chunk.prefix(remaining))
    isTruncated = isTruncated || chunk.count > remaining
  }
}

private struct VerificationDescriptorPipe {
  private(set) var readDescriptor: Int32
  private(set) var writeDescriptor: Int32

  init() throws {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw BoundedVerificationProcessError.launchFailed }
    readDescriptor = descriptors[0]
    writeDescriptor = descriptors[1]
    guard Self.setCloseOnExec(readDescriptor), Self.setCloseOnExec(writeDescriptor),
      Self.setNonBlocking(readDescriptor)
    else {
      Darwin.close(readDescriptor)
      Darwin.close(writeDescriptor)
      throw BoundedVerificationProcessError.launchFailed
    }
  }

  mutating func takeRead() -> Int32 {
    let descriptor = readDescriptor
    readDescriptor = -1
    return descriptor
  }

  mutating func closeWrite() {
    guard writeDescriptor >= 0 else { return }
    Darwin.close(writeDescriptor)
    writeDescriptor = -1
  }

  mutating func closeBoth() {
    if readDescriptor >= 0 { Darwin.close(readDescriptor) }
    if writeDescriptor >= 0 { Darwin.close(writeDescriptor) }
    readDescriptor = -1
    writeDescriptor = -1
  }

  private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
    fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
  }

  private static func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }
}
