import Darwin
import Foundation

@_silgen_name("posix_spawn_file_actions_addfchdir_np")
private func bridgeSpawnFileActionsAddFchdir(
  _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
  _ descriptor: Int32
) -> Int32

final class OpenedWorkingDirectory: @unchecked Sendable {
  let url: URL
  let descriptor: Int32
  private let device: UInt64
  private let inode: UInt64

  init(canonicalURL: URL) throws {
    var information = stat()
    let opened = Darwin.open(canonicalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0, fstat(opened, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR
    else {
      if opened >= 0 { Darwin.close(opened) }
      throw GitEvidenceError.invalidAuthorizedRoot
    }
    url = canonicalURL
    descriptor = opened
    device = UInt64(information.st_dev)
    inode = UInt64(information.st_ino)
  }

  deinit {
    Darwin.close(descriptor)
  }

  func validatePathIdentity() throws {
    var information = stat()
    let result = url.path.withCString { Darwin.lstat($0, &information) }
    guard result == 0,
      information.st_mode & S_IFMT == S_IFDIR,
      UInt64(information.st_dev) == device,
      UInt64(information.st_ino) == inode
    else {
      throw GitEvidenceError.invalidAuthorizedRoot
    }
  }
}

enum BoundedProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case outputLimit
}

struct BoundedProcessResult: Equatable, Sendable {
  let termination: BoundedProcessTermination
  let standardOutput: Data
  let standardError: Data
  let standardOutputTruncated: Bool
  let standardErrorTruncated: Bool
}

struct BoundedProcessConfiguration: Sendable {
  let executableURL: URL
  let arguments: [String]
  let workingDirectory: OpenedWorkingDirectory
  let environment: [String]
  let timeout: Duration
  let terminationGracePeriod: Duration
  let maximumStandardOutputBytes: Int
  let maximumStandardErrorBytes: Int
}

enum BoundedProcessError: Error, Equatable, Sendable {
  case invalidConfiguration
  case launchFailed
  case timedOut
  case waitFailed
}

struct BoundedProcessRunner: Sendable {
  func run(_ configuration: BoundedProcessConfiguration) async throws -> BoundedProcessResult {
    try Self.validate(configuration)
    var child = try spawn(configuration)
    do {
      return try await monitor(&child, configuration: configuration)
    } catch {
      _ = await terminateAndReap(
        &child,
        gracePeriod: configuration.terminationGracePeriod
      )
      child.drainAfterExit()
      throw error
    }
  }

  private func monitor(
    _ child: inout ChildProcess,
    configuration: BoundedProcessConfiguration
  ) async throws -> BoundedProcessResult {
    let clock = ContinuousClock()
    let timeout = min(max(configuration.timeout, .milliseconds(1)), .seconds(120))
    let deadline = clock.now.advanced(by: timeout)

    while true {
      child.drainOutput()
      if child.outputExceededLimit {
        _ = await terminateAndReap(
          &child,
          gracePeriod: configuration.terminationGracePeriod
        )
        child.drainAfterExit()
        return child.result(termination: .outputLimit)
      }
      if let code = try child.pollExit() {
        child.drainAfterExit()
        return child.result(termination: .exited(code))
      }
      if Task.isCancelled { throw CancellationError() }
      if clock.now >= deadline { throw BoundedProcessError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func terminateAndReap(
    _ child: inout ChildProcess,
    gracePeriod: Duration
  ) async -> Int32? {
    _ = Darwin.kill(child.pid, SIGTERM)
    let clock = ContinuousClock()
    let grace = min(max(gracePeriod, .zero), .seconds(2))
    let deadline = clock.now.advanced(by: grace)
    while clock.now < deadline {
      child.drainOutput()
      if let code = try? child.pollExit() { return code }
      try? await Task.sleep(for: .milliseconds(10))
    }

    _ = Darwin.kill(child.pid, SIGKILL)
    let killDeadline = clock.now.advanced(by: .seconds(2))
    while clock.now < killDeadline {
      child.drainOutput()
      if let code = try? child.pollExit() { return code }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  private func spawn(_ configuration: BoundedProcessConfiguration) throws -> ChildProcess {
    var outputPipe = try DescriptorPipe()
    defer { outputPipe.closeBoth() }
    var errorPipe = try DescriptorPipe()
    defer { errorPipe.closeBoth() }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw BoundedProcessError.launchFailed
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      throw BoundedProcessError.launchFailed
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
    guard status == 0 else { throw BoundedProcessError.launchFailed }
    outputPipe.closeWrite()
    errorPipe.closeWrite()
    return ChildProcess(
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
    outputPipe: DescriptorPipe,
    errorPipe: DescriptorPipe
  ) throws {
    guard
      posix_spawn_file_actions_addopen(
        &actions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &actions,
        outputPipe.writeDescriptor,
        STDOUT_FILENO
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &actions,
        errorPipe.writeDescriptor,
        STDERR_FILENO
      ) == 0,
      bridgeSpawnFileActionsAddFchdir(&actions, currentDirectoryDescriptor) == 0
    else {
      throw BoundedProcessError.launchFailed
    }
  }

  private func configureSpawnAttributes(
    _ attributes: inout posix_spawnattr_t?
  ) throws {
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
      sigaddset(&defaults, signal)
    }
    var mask = sigset_t()
    sigemptyset(&mask)
    let flags = Int16(
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    )
    guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
      posix_spawnattr_setsigmask(&attributes, &mask) == 0,
      posix_spawnattr_setflags(&attributes, flags) == 0
    else {
      throw BoundedProcessError.launchFailed
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

  private static func validate(_ configuration: BoundedProcessConfiguration) throws {
    let strings =
      [configuration.executableURL.path, configuration.workingDirectory.url.path]
      + configuration.arguments + configuration.environment
    guard
      configuration.executableURL.isFileURL,
      configuration.workingDirectory.url.isFileURL,
      configuration.maximumStandardOutputBytes > 0,
      configuration.maximumStandardErrorBytes > 0,
      strings.allSatisfy({ !$0.contains("\0") })
    else {
      throw BoundedProcessError.invalidConfiguration
    }
  }
}

private struct ChildProcess {
  let pid: pid_t
  private var outputDescriptor: Int32
  private var errorDescriptor: Int32
  private var standardOutput: BoundedByteBuffer
  private var standardError: BoundedByteBuffer

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
    standardOutput = BoundedByteBuffer(limit: maximumStandardOutputBytes)
    standardError = BoundedByteBuffer(limit: maximumStandardErrorBytes)
  }

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

  mutating func pollExit() throws -> Int32? {
    var status: Int32 = 0
    var result: pid_t = -1
    repeat {
      result = waitpid(pid, &status, WNOHANG)
    } while result < 0 && errno == EINTR
    if result == 0 { return nil }
    if result < 0, errno == ECHILD { return 255 }
    guard result == pid else { throw BoundedProcessError.waitFailed }
    return Self.exitCode(status)
  }

  func result(termination: BoundedProcessTermination) -> BoundedProcessResult {
    BoundedProcessResult(
      termination: termination,
      standardOutput: standardOutput.data,
      standardError: standardError.data,
      standardOutputTruncated: standardOutput.isTruncated,
      standardErrorTruncated: standardError.isTruncated
    )
  }

  private static func drain(
    descriptor: inout Int32,
    into buffer: inout BoundedByteBuffer,
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

private struct BoundedByteBuffer {
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

private struct DescriptorPipe {
  private(set) var readDescriptor: Int32
  private(set) var writeDescriptor: Int32

  init() throws {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw BoundedProcessError.launchFailed }
    readDescriptor = descriptors[0]
    writeDescriptor = descriptors[1]
    guard Self.setCloseOnExec(readDescriptor), Self.setCloseOnExec(writeDescriptor),
      Self.setNonBlocking(readDescriptor)
    else {
      Darwin.close(readDescriptor)
      Darwin.close(writeDescriptor)
      throw BoundedProcessError.launchFailed
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
