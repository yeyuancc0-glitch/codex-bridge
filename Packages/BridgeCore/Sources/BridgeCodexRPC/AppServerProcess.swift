@preconcurrency import Foundation

#if os(Windows)
  import WinSDK
#endif

public struct AppServerConfiguration: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let currentDirectoryURL: URL?
  public let environment: [String: String]?
  public let maximumProtocolLineBytes: Int
  public let stderrBufferBytes: Int

  let launchFailureReason: String?

  public init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil,
    maximumProtocolLineBytes: Int = 64 * 1024 * 1024,
    stderrBufferBytes: Int = 64 * 1024
  ) {
    self.init(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: environment,
      maximumProtocolLineBytes: maximumProtocolLineBytes,
      stderrBufferBytes: stderrBufferBytes,
      launchFailureReason: nil
    )
  }

  init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    environment: [String: String]?,
    maximumProtocolLineBytes: Int,
    stderrBufferBytes: Int,
    launchFailureReason: String?
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.currentDirectoryURL = currentDirectoryURL
    self.environment = environment
    self.maximumProtocolLineBytes = max(1, maximumProtocolLineBytes)
    self.stderrBufferBytes = max(0, stderrBufferBytes)
    self.launchFailureReason = launchFailureReason
  }
}

private final class AppServerProcessState: @unchecked Sendable {
  let process = Process()
  let stdinPipe = Pipe()
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  let exitLock = NSLock()
  var exitStatus: Int32?
  var exitWaiters: [CheckedContinuation<Int32, Never>] = []

  func terminateIfRunning() {
    if process.isRunning {
      process.terminate()
    }
  }

  func closeHandles() {
    try? stdinPipe.fileHandleForWriting.close()
    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForWriting.close()
  }

  func closeParentCopiesOfChildHandles() {
    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
  }

  func recordExit(_ status: Int32) {
    exitLock.lock()
    guard exitStatus == nil else {
      exitLock.unlock()
      return
    }
    exitStatus = status
    let waiters = exitWaiters
    exitWaiters.removeAll(keepingCapacity: false)
    exitLock.unlock()
    for waiter in waiters {
      waiter.resume(returning: status)
    }
  }

  func waitForExit() async -> Int32 {
    await withCheckedContinuation { continuation in
      exitLock.lock()
      if let exitStatus {
        exitLock.unlock()
        continuation.resume(returning: exitStatus)
      } else {
        exitWaiters.append(continuation)
        exitLock.unlock()
      }
    }
  }
}

private actor BoundedDataBuffer {
  private let limit: Int
  private var data = Data()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) {
    guard limit > 0, !chunk.isEmpty else { return }
    if chunk.count >= limit {
      data = Data(chunk.suffix(limit))
      return
    }

    data.append(chunk)
    let overflow = data.count - limit
    if overflow > 0 {
      data.removeFirst(overflow)
    }
  }

  func snapshot() -> Data {
    data
  }
}

public actor AppServerProcess {
  private let configuration: AppServerConfiguration
  private let stderrBuffer: BoundedDataBuffer
  private var state: AppServerProcessState?
  private var transport: JSONLineTransport?
  private var dispatcher: RPCDispatcher?
  private var stderrTask: Task<Void, Never>?
  private var stderrContinuation: AsyncStream<Data>.Continuation?
  private var hasStarted = false

  public init(configuration: AppServerConfiguration = .codex()) {
    self.configuration = configuration
    stderrBuffer = BoundedDataBuffer(limit: configuration.stderrBufferBytes)
  }

  public func start(dispatcher: RPCDispatcher) async throws {
    guard !hasStarted else { throw CodexRPCError.alreadyStarted }
    hasStarted = true

    if let reason = configuration.launchFailureReason {
      await dispatcher.terminate(with: .processLaunchFailed(reason))
      throw CodexRPCError.processLaunchFailed(reason)
    }

    let state = AppServerProcessState()
    configure(state.process, with: configuration, pipes: state)
    let transport = JSONLineTransport(
      input: state.stdinPipe.fileHandleForWriting,
      output: state.stdoutPipe.fileHandleForReading,
      dispatcher: dispatcher,
      maximumLineBytes: configuration.maximumProtocolLineBytes
    )

    state.process.terminationHandler = { process in
      state.recordExit(process.terminationStatus)
      Task {
        await dispatcher.terminate(with: .processExited(process.terminationStatus))
      }
    }
    try await transport.start {
      state.terminateIfRunning()
    }
    let stderrReader = makeStderrReader(
      handle: state.stderrPipe.fileHandleForReading,
      buffer: stderrBuffer
    )
    stderrTask = stderrReader.task
    stderrContinuation = stderrReader.continuation

    do {
      try state.process.run()
      state.closeParentCopiesOfChildHandles()
    } catch {
      await transport.stop()
      state.stderrPipe.fileHandleForReading.readabilityHandler = nil
      stderrContinuation?.finish()
      stderrContinuation = nil
      stderrTask?.cancel()
      stderrTask = nil
      state.closeHandles()
      await dispatcher.terminate(with: .processLaunchFailed(error.localizedDescription))
      throw CodexRPCError.processLaunchFailed(error.localizedDescription)
    }

    self.state = state
    self.transport = transport
    self.dispatcher = dispatcher
  }

  public func send(_ value: JSONValue) async throws {
    guard let state, state.process.isRunning, let transport else {
      throw CodexRPCError.notStarted
    }
    try await transport.write(value)
  }

  public func stop() async {
    guard let state else { return }
    await transport?.stop()
    state.terminateIfRunning()
    await waitForExitOrKill(state)
    let status = await state.waitForExit()
    await dispatcher?.terminate(with: .processExited(status))
    state.stderrPipe.fileHandleForReading.readabilityHandler = nil
    stderrContinuation?.finish()
    stderrContinuation = nil
    stderrTask?.cancel()
    stderrTask = nil
    state.closeHandles()
    transport = nil
    dispatcher = nil
    self.state = nil
  }

  public func stderrSnapshot() async -> Data {
    await stderrBuffer.snapshot()
  }

  private func configure(
    _ process: Process,
    with configuration: AppServerConfiguration,
    pipes: AppServerProcessState
  ) {
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.currentDirectoryURL = configuration.currentDirectoryURL
    if let environment = configuration.environment {
      process.environment = environment
    }
    process.standardInput = pipes.stdinPipe
    process.standardOutput = pipes.stdoutPipe
    process.standardError = pipes.stderrPipe
  }

  private func makeStderrReader(
    handle: FileHandle,
    buffer: BoundedDataBuffer
  ) -> (task: Task<Void, Never>, continuation: AsyncStream<Data>.Continuation) {
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingNewest(8)
    )
    handle.readabilityHandler = { readableHandle in
      let data = readableHandle.availableData
      if data.isEmpty {
        pair.continuation.finish()
      } else {
        pair.continuation.yield(data)
      }
    }
    let task = Task.detached(priority: .utility) {
      for await data in pair.stream {
        await buffer.append(data)
      }
    }
    return (task, pair.continuation)
  }

  private func waitForExitOrKill(_ state: AppServerProcessState) async {
    for _ in 0..<40 {
      guard state.process.isRunning else { return }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard state.process.isRunning else { return }
    #if os(Windows)
      let processID = DWORD(UInt32(bitPattern: state.process.processIdentifier))
      if let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, processID) {
        _ = TerminateProcess(handle, 1)
        _ = CloseHandle(handle)
      }
    #else
      kill(state.process.processIdentifier, SIGKILL)
    #endif
    _ = await state.waitForExit()
  }
}
