#if canImport(WinSDK)
  import BridgeProcessRuntime
  @preconcurrency import Foundation

  public actor AppServerProcess {
    private let configuration: AppServerConfiguration
    private let stderrBuffer: AppServerStderrBuffer
    private var process: WindowsJobProcess?
    private var transport: JSONLineTransport?
    private var dispatcher: RPCDispatcher?
    private var exitTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var hasStarted = false

    public init(configuration: AppServerConfiguration = .codex()) {
      self.configuration = configuration
      stderrBuffer = AppServerStderrBuffer(limit: configuration.stderrBufferBytes)
    }

    public func start(dispatcher: RPCDispatcher) async throws {
      guard !hasStarted else { throw CodexRPCError.alreadyStarted }
      hasStarted = true
      if let reason = configuration.launchFailureReason {
        await dispatcher.terminate(with: .processLaunchFailed(reason))
        throw CodexRPCError.processLaunchFailed(reason)
      }

      let process: WindowsJobProcess
      do {
        process = try WindowsJobProcess(
          configuration: WindowsJobProcessConfiguration(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            currentDirectoryURL: configuration.currentDirectoryURL,
            environment: configuration.environment
          )
        )
      } catch {
        let message = error.localizedDescription
        await dispatcher.terminate(with: .processLaunchFailed(message))
        throw CodexRPCError.processLaunchFailed(message)
      }

      let transport = JSONLineTransport(
        input: process.standardInput,
        output: process.standardOutput,
        dispatcher: dispatcher,
        maximumLineBytes: configuration.maximumProtocolLineBytes
      )
      do {
        try await transport.start {
          _ = process.terminateTree()
        }
      } catch {
        _ = process.terminateTree()
        _ = process.waitForExit(timeout: .seconds(5))
        process.close()
        throw error
      }

      let stderrReader = makeStderrReader(
        handle: process.standardError,
        buffer: stderrBuffer
      )
      stderrTask = stderrReader.task
      stderrContinuation = stderrReader.continuation
      exitTask = Task.detached(priority: .utility) {
        let status = await process.waitForExit()
        await dispatcher.terminate(with: .processExited(status))
      }
      self.process = process
      self.transport = transport
      self.dispatcher = dispatcher
    }

    public func send(_ value: JSONValue) async throws {
      guard let process, process.isRunning, let transport else {
        throw CodexRPCError.notStarted
      }
      try await transport.write(value)
    }

    public func stop() async {
      guard let process else { return }
      await transport?.stop()
      await waitForExitOrKill(process)
      let status = process.waitForExit(timeout: .seconds(1)) ?? -1
      await dispatcher?.terminate(with: .processExited(status))
      process.standardError.readabilityHandler = nil
      stderrContinuation?.finish()
      stderrContinuation = nil
      stderrTask?.cancel()
      stderrTask = nil
      exitTask?.cancel()
      exitTask = nil
      process.close()
      transport = nil
      dispatcher = nil
      self.process = nil
    }

    public func stderrSnapshot() async -> Data {
      await stderrBuffer.snapshot()
    }

    private func makeStderrReader(
      handle: FileHandle,
      buffer: AppServerStderrBuffer
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

    private func waitForExitOrKill(_ process: WindowsJobProcess) async {
      for _ in 0..<20 {
        guard process.isRunning else { return }
        try? await Task.sleep(for: .milliseconds(25))
      }
      guard process.isRunning else { return }
      _ = process.terminateTree()
      _ = process.waitForExit(timeout: .seconds(5))
    }
  }
#endif
