#if canImport(WinSDK)
  import BridgeProcessRuntime
  import Foundation
  import WinSDK

  public final class DirectProcessLifetime: @unchecked Sendable {
    public let pid: Int32
    private let process: WindowsJobProcess
    private let output: DirectCommandOutputCollector
    private let outputHandles: [FileHandle]
    private let lock = NSLock()
    private let inputLock = NSLock()
    private var termination: DirectProcessTermination?
    private var processIdentity: DirectProcessIdentity?
    private var inputClosed = false
    private var forcedTerminationCode: Int32?

    public var identity: DirectProcessIdentity? {
      lock.lock()
      defer { lock.unlock() }
      return processIdentity
    }

    public init(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String]?,
      usePTY: Bool,
      output: DirectCommandOutputCollector,
      sandboxRoot: String? = nil,
      requiresSandbox: Bool = true,
      denyNetwork: Bool = false
    ) throws {
      guard let executable = argv.first,
        !executable.isEmpty,
        argv.count <= 128,
        !usePTY
      else {
        throw DirectProcessError.invalidArgument
      }
      guard !requiresSandbox || sandboxRoot != nil || workingDirectory != nil else {
        throw DirectProcessError.sandboxUnavailable
      }
      guard requiresSandbox || !denyNetwork else { throw DirectProcessError.sandboxUnavailable }

      let process: WindowsJobProcess
      do {
        process = try WindowsJobProcess(
          configuration: WindowsJobProcessConfiguration(
            executableURL: URL(fileURLWithPath: executable),
            arguments: Array(argv.dropFirst()),
            currentDirectoryURL: workingDirectory.map {
              URL(fileURLWithPath: $0, isDirectory: true)
            },
            environment: Self.windowsEnvironment(environment),
            appContainer: requiresSandbox
              ? WindowsAppContainerConfiguration(
                profileName: "org.codexbridge.direct",
                projectRootURL: URL(
                  fileURLWithPath: sandboxRoot ?? workingDirectory!,
                  isDirectory: true
                ),
                allowsNetwork: !denyNetwork
              ) : nil
          )
        )
      } catch let error as WindowsJobProcessError {
        switch error {
        case .invalidArguments, .invalidWorkingDirectory, .invalidEnvironment,
          .commandLineTooLong:
          throw DirectProcessError.invalidArgument
        case .win32(_, let code):
          throw DirectProcessError.processLaunchFailed(code)
        case .appContainer:
          throw DirectProcessError.sandboxUnavailable
        case .executable, .executableIdentityChanged:
          throw DirectProcessError.processLaunchFailed(193)
        }
      } catch {
        throw DirectProcessError.processLaunchFailed(-1)
      }

      guard process.processIdentifier <= UInt32(Int32.max) else {
        _ = process.terminateTree()
        process.close()
        throw DirectProcessError.processLaunchFailed(534)
      }
      self.process = process
      self.output = output
      outputHandles = [process.standardOutput, process.standardError]
      pid = Int32(process.processIdentifier)
      processIdentity = Self.identity(from: process.identity)

      for handle in outputHandles {
        handle.readabilityHandler = { [weak self] readableHandle in
          let data = readableHandle.availableData
          if !data.isEmpty {
            self?.output.append(data)
          }
        }
      }
    }

    public func writeStdin(_ data: Data) throws {
      inputLock.lock()
      defer { inputLock.unlock() }
      guard !inputClosed else { throw DirectProcessError.stdinUnavailable }
      do {
        try process.standardInput.write(contentsOf: data)
      } catch {
        throw DirectProcessError.stdinUnavailable
      }
    }

    public func closeStdin() {
      inputLock.lock()
      defer { inputLock.unlock() }
      guard !inputClosed else { return }
      inputClosed = true
      try? process.standardInput.close()
    }

    public func terminateGroup() {
      forceTerminateTree()
    }

    public func killGroup() {
      forceTerminateTree()
    }

    public var isRunning: Bool {
      if process.isRunning { return true }
      _ = reapIfExited(gracePeriod: .zero)
      return false
    }

    public func reapIfExited(
      gracePeriod: Duration = .milliseconds(200)
    ) -> DirectProcessTermination? {
      lock.lock()
      if let termination {
        lock.unlock()
        return termination
      }
      lock.unlock()
      guard let status = process.waitForExit(timeout: gracePeriod) else { return nil }
      return recordExit(status)
    }

    public func waitForExit(timeout: Duration) -> DirectProcessTermination? {
      lock.lock()
      if let termination {
        lock.unlock()
        return termination
      }
      lock.unlock()
      guard let status = process.waitForExit(timeout: timeout) else { return nil }
      return recordExit(status)
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
      let recordedTermination = termination
      lock.unlock()
      guard recordedTermination != nil else { return }
      for handle in outputHandles {
        handle.readabilityHandler = nil
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty { output.append(data) }
      }
    }

    public func close() {
      for handle in outputHandles {
        handle.readabilityHandler = nil
      }
      closeStdin()
      process.close()
    }

    private func forceTerminateTree() {
      guard process.isRunning else {
        _ = reapIfExited(gracePeriod: .zero)
        return
      }
      lock.lock()
      forcedTerminationCode = 1
      lock.unlock()
      _ = process.terminateTree()
    }

    private func recordExit(_ status: Int32) -> DirectProcessTermination {
      lock.lock()
      defer { lock.unlock() }
      if let termination { return termination }
      let recorded: DirectProcessTermination
      if let forcedTerminationCode {
        recorded = .killed(forcedTerminationCode)
      } else {
        recorded = .exited(status)
      }
      termination = recorded
      return recorded
    }

    private static func windowsEnvironment(
      _ environment: [String: String]?
    ) -> [String: String] {
      if let environment { return environment }
      let current = ProcessInfo.processInfo.environment
      let allowed = [
        "SystemRoot", "WINDIR", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "APPDATA",
        "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "PATH", "PATHEXT",
      ]
      var result: [String: String] = [:]
      for key in allowed {
        if let value = WindowsPath.environmentValue(key, in: current) {
          result[key] = value
        }
      }
      return result
    }

    private static func identity(
      from identity: WindowsJobProcessIdentity
    ) -> DirectProcessIdentity? {
      guard identity.processID <= UInt32(Int32.max) else { return nil }
      let micros = identity.creationTime100Nanoseconds / 10
      guard micros <= UInt64(Int64.max) else { return nil }
      let pid = Int32(identity.processID)
      return DirectProcessIdentity(
        pid: pid,
        startTimeMicros: Int64(micros),
        processGroupID: pid
      )
    }

    public static func identity(of processID: Int32) -> DirectProcessIdentity? {
      guard processID > 1,
        let identity = WindowsJobProcess.currentIdentity(processID: UInt32(processID))
      else { return nil }
      return Self.identity(from: identity)
    }

    public static func matchesCurrentProcess(_ identity: DirectProcessIdentity) -> Bool {
      guard identity.processGroupID == identity.pid,
        let current = Self.identity(of: identity.pid)
      else { return false }
      return current == identity
    }

    @discardableResult
    public static func terminateIfMatches(_ identity: DirectProcessIdentity) -> Bool {
      guard matchesCurrentProcess(identity) else { return false }
      let handle = OpenProcess(
        DWORD(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION),
        false,
        DWORD(identity.pid)
      )
      guard let handle else { return false }
      defer { CloseHandle(handle) }
      return TerminateProcess(handle, 1)
    }
  }
#endif
