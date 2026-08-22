#if canImport(WinSDK)
  import BridgePlatform
  import CRT
  import Foundation
  import WinSDK

  public enum WindowsJobProcessError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidWorkingDirectory
    case invalidEnvironment
    case commandLineTooLong
    case win32(operation: String, code: Int32)
    case executable(WindowsExecutableValidationError)
  }

  extension WindowsJobProcessError: LocalizedError {
    public var errorDescription: String? {
      switch self {
      case .invalidArguments:
        return "invalid process arguments"
      case .invalidWorkingDirectory:
        return "invalid Windows working directory"
      case .invalidEnvironment:
        return "invalid Windows process environment"
      case .commandLineTooLong:
        return "Windows command line exceeds 32767 UTF-16 code units"
      case .win32(let operation, let code):
        return "\(operation) failed with Win32 error \(code)"
      case .executable(let error):
        return "executable validation failed: \(error)"
      }
    }
  }

  public struct WindowsJobProcessConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    public let environment: [String: String]?
    public let createNewProcessGroup: Bool

    public init(
      executableURL: URL,
      arguments: [String],
      currentDirectoryURL: URL? = nil,
      environment: [String: String]? = nil,
      createNewProcessGroup: Bool = true
    ) {
      self.executableURL = executableURL
      self.arguments = arguments
      self.currentDirectoryURL = currentDirectoryURL
      self.environment = environment
      self.createNewProcessGroup = createNewProcessGroup
    }
  }

  public struct WindowsJobProcessIdentity: Equatable, Sendable {
    public let processID: UInt32
    public let creationTime100Nanoseconds: UInt64

    public init(processID: UInt32, creationTime100Nanoseconds: UInt64) {
      self.processID = processID
      self.creationTime100Nanoseconds = creationTime100Nanoseconds
    }
  }

  public final class WindowsJobProcess: @unchecked Sendable {
    public let processIdentifier: UInt32
    public let identity: WindowsJobProcessIdentity
    public let standardInput: FileHandle
    public let standardOutput: FileHandle
    public let standardError: FileHandle

    private let state: HandleState

    public init(
      configuration: WindowsJobProcessConfiguration,
      processArchitecture: PlatformArchitecture = TargetPlatformArchitecture.current
    ) throws {
      guard configuration.arguments.count <= 128,
        configuration.arguments.allSatisfy({ !$0.contains("\0") })
      else {
        throw WindowsJobProcessError.invalidArguments
      }
      let lease: WindowsExecutableLease
      do {
        lease = try WindowsExecutableLease(
          url: configuration.executableURL,
          processArchitecture: processArchitecture
        )
      } catch let error as WindowsExecutableValidationError {
        throw WindowsJobProcessError.executable(error)
      }
      defer { lease.close() }

      let workingDirectory = try Self.validatedWorkingDirectory(
        configuration.currentDirectoryURL
      )
      let commandLine = try WindowsCommandLine.encode(
        [lease.canonicalURL.path] + configuration.arguments
      )
      guard commandLine.utf16.count + 1 <= 32_767 else {
        throw WindowsJobProcessError.commandLineTooLong
      }
      let environmentBlock = try Self.environmentBlock(configuration.environment)

      let stdinPipe = try RawPipe.make(childReads: true)
      let stdoutPipe = try RawPipe.make(childReads: false)
      let stderrPipe = try RawPipe.make(childReads: false)
      var processInfo = PROCESS_INFORMATION()
      let job = try Self.makeKillOnCloseJob()
      var launchSucceeded = false
      defer {
        if !launchSucceeded {
          stdinPipe.closeAll()
          stdoutPipe.closeAll()
          stderrPipe.closeAll()
          CloseHandle(job)
        }
      }

      try Self.createSuspendedProcess(
        executablePath: lease.canonicalURL.path,
        commandLine: commandLine,
        workingDirectory: workingDirectory,
        environmentBlock: environmentBlock,
        childHandles: [stdinPipe.child, stdoutPipe.child, stderrPipe.child],
        createNewProcessGroup: configuration.createNewProcessGroup,
        processInfo: &processInfo
      )
      guard AssignProcessToJobObject(job, processInfo.hProcess) else {
        let code = Int32(GetLastError())
        TerminateProcess(processInfo.hProcess, 1)
        CloseHandle(processInfo.hThread)
        CloseHandle(processInfo.hProcess)
        throw WindowsJobProcessError.win32(operation: "AssignProcessToJobObject", code: code)
      }
      guard ResumeThread(processInfo.hThread) != DWORD.max else {
        let code = Int32(GetLastError())
        TerminateJobObject(job, 1)
        CloseHandle(processInfo.hThread)
        CloseHandle(processInfo.hProcess)
        throw WindowsJobProcessError.win32(operation: "ResumeThread", code: code)
      }
      CloseHandle(processInfo.hThread)
      stdinPipe.closeChild()
      stdoutPipe.closeChild()
      stderrPipe.closeChild()

      do {
        standardInput = try stdinPipe.makeParentFileHandle(readOnly: false)
        standardOutput = try stdoutPipe.makeParentFileHandle(readOnly: true)
        standardError = try stderrPipe.makeParentFileHandle(readOnly: true)
      } catch {
        TerminateJobObject(job, 1)
        WaitForSingleObject(processInfo.hProcess, 5_000)
        CloseHandle(processInfo.hProcess)
        throw error
      }

      let processIdentity: WindowsJobProcessIdentity
      do {
        processIdentity = try Self.readIdentity(
          processHandle: processInfo.hProcess,
          processID: processInfo.dwProcessId
        )
      } catch {
        TerminateJobObject(job, 1)
        WaitForSingleObject(processInfo.hProcess, 5_000)
        try? standardInput.close()
        try? standardOutput.close()
        try? standardError.close()
        CloseHandle(processInfo.hProcess)
        throw error
      }

      processIdentifier = processInfo.dwProcessId
      identity = processIdentity
      state = HandleState(process: processInfo.hProcess, job: job)
      launchSucceeded = true
    }

    deinit {
      close()
    }

    public var isRunning: Bool {
      state.isRunning
    }

    public func waitForExit() async -> Int32 {
      await Task.detached(priority: .utility) { [state] in
        state.waitForExit(timeoutMilliseconds: DWORD(INFINITE)) ?? -1
      }.value
    }

    public func waitForExit(timeout: Duration) -> Int32? {
      state.waitForExit(timeoutMilliseconds: Self.milliseconds(timeout))
    }

    /// The child is created with `CREATE_NO_WINDOW`, so it has no console that
    /// can receive `CTRL_BREAK_EVENT`. Callers must use a protocol-level stop or
    /// fall back to the Job Object tree terminator.
    @discardableResult
    public func requestGracefulTermination() -> Bool {
      false
    }

    @discardableResult
    public func terminateTree(exitCode: UInt32 = 1) -> Bool {
      state.terminateTree(exitCode: exitCode)
    }

    public func close() {
      try? standardInput.close()
      try? standardOutput.close()
      try? standardError.close()
      state.close()
    }

    public static func currentIdentity(processID: UInt32) -> WindowsJobProcessIdentity? {
      let handle = OpenProcess(
        DWORD(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE),
        false,
        processID
      )
      guard let handle else { return nil }
      defer { CloseHandle(handle) }
      return try? readIdentity(processHandle: handle, processID: processID)
    }

    private static func validatedWorkingDirectory(_ url: URL?) throws -> String? {
      guard let url else { return nil }
      do {
        return try WindowsLocalPathValidator.validate(url.path, kind: .directory)
      } catch {
        throw WindowsJobProcessError.invalidWorkingDirectory
      }
    }

    private static func environmentBlock(_ environment: [String: String]?) throws -> String {
      let source = environment ?? ProcessInfo.processInfo.environment
      var normalized: [String: (key: String, value: String)] = [:]
      normalized.reserveCapacity(source.count + 1)

      for (key, value) in source {
        guard !key.isEmpty,
          !key.contains("="),
          !key.contains("\0"),
          !value.contains("\0")
        else {
          throw WindowsJobProcessError.invalidEnvironment
        }
        let lookup = key.lowercased()
        guard normalized[lookup] == nil else {
          throw WindowsJobProcessError.invalidEnvironment
        }
        normalized[lookup] = (key, value)
      }
      normalized["nodefaultcurrentdirectoryinexepath"] = (
        "NoDefaultCurrentDirectoryInExePath",
        "1"
      )

      let entries = normalized.values.sorted {
        $0.key.caseInsensitiveCompare($1.key) == .orderedAscending
      }.map { "\($0.key)=\($0.value)" }
      let block = entries.joined(separator: "\0") + "\0\0"
      guard block.utf16.count <= 32_767 else {
        throw WindowsJobProcessError.invalidEnvironment
      }
      return block
    }

    private static func makeKillOnCloseJob() throws -> HANDLE {
      guard let job = CreateJobObjectW(nil, nil) else {
        throw WindowsJobProcessError.win32(
          operation: "CreateJobObjectW",
          code: Int32(GetLastError())
        )
      }
      var information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      information.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      guard
        SetInformationJobObject(
          job,
          JobObjectExtendedLimitInformation,
          &information,
          DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
        )
      else {
        let code = Int32(GetLastError())
        CloseHandle(job)
        throw WindowsJobProcessError.win32(operation: "SetInformationJobObject", code: code)
      }
      return job
    }

    private static func createSuspendedProcess(
      executablePath: String,
      commandLine: String,
      workingDirectory: String?,
      environmentBlock: String,
      childHandles: [HANDLE],
      createNewProcessGroup: Bool,
      processInfo: inout PROCESS_INFORMATION
    ) throws {
      let application = WideBuffer(executablePath)
      let mutableCommandLine = WideBuffer(commandLine)
      let directory = workingDirectory.map(WideBuffer.init)
      let environment = WideBuffer(environmentBlock, appendNull: false)
      var startupInfo = STARTUPINFOEXW()
      startupInfo.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      startupInfo.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW)
      startupInfo.StartupInfo.wShowWindow = WORD(SW_HIDE)
      startupInfo.StartupInfo.hStdInput = childHandles[0]
      startupInfo.StartupInfo.hStdOutput = childHandles[1]
      startupInfo.StartupInfo.hStdError = childHandles[2]

      let attributes = try ProcessAttributeList(handles: childHandles)
      startupInfo.lpAttributeList = attributes.pointer
      var flags = DWORD(
        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT
          | CREATE_NO_WINDOW
      )
      if createNewProcessGroup { flags |= DWORD(CREATE_NEW_PROCESS_GROUP) }

      let created = CreateProcessW(
        application.pointer,
        mutableCommandLine.pointer,
        nil,
        nil,
        true,
        flags,
        UnsafeMutableRawPointer(environment.pointer),
        directory?.pointer,
        &startupInfo.StartupInfo,
        &processInfo
      )
      guard created else {
        throw WindowsJobProcessError.win32(
          operation: "CreateProcessW",
          code: Int32(GetLastError())
        )
      }
    }

    private static func readIdentity(
      processHandle: HANDLE,
      processID: UInt32
    ) throws -> WindowsJobProcessIdentity {
      var creation = FILETIME()
      var exit = FILETIME()
      var kernel = FILETIME()
      var user = FILETIME()
      guard GetProcessTimes(processHandle, &creation, &exit, &kernel, &user) else {
        throw WindowsJobProcessError.win32(
          operation: "GetProcessTimes",
          code: Int32(GetLastError())
        )
      }
      let ticks = (UInt64(creation.dwHighDateTime) << 32) | UInt64(creation.dwLowDateTime)
      return WindowsJobProcessIdentity(
        processID: processID,
        creationTime100Nanoseconds: ticks
      )
    }

    private static func milliseconds(_ duration: Duration) -> DWORD {
      let parts = duration.components
      guard parts.seconds >= 0 else { return 0 }
      let seconds = UInt64(parts.seconds)
      let fractional = UInt64(max(0, parts.attoseconds / 1_000_000_000_000_000))
      let total = seconds.multipliedReportingOverflow(by: 1_000)
      guard !total.overflow else { return DWORD.max - 1 }
      let sum = total.partialValue.addingReportingOverflow(fractional)
      guard !sum.overflow else { return DWORD.max - 1 }
      return DWORD(min(sum.partialValue, UInt64(DWORD.max - 1)))
    }
  }

  private final class HandleState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: HANDLE?
    private var job: HANDLE?

    init(process: HANDLE, job: HANDLE) {
      self.process = process
      self.job = job
    }

    var isRunning: Bool {
      lock.lock()
      defer { lock.unlock() }
      guard let process else { return false }
      return WaitForSingleObject(process, 0) == WAIT_TIMEOUT
    }

    func waitForExit(timeoutMilliseconds: DWORD) -> Int32? {
      guard let process = duplicateProcessHandle() else { return nil }
      defer { CloseHandle(process) }
      guard WaitForSingleObject(process, timeoutMilliseconds) == WAIT_OBJECT_0 else { return nil }
      var code = DWORD(0)
      guard GetExitCodeProcess(process, &code) else { return nil }
      return Int32(bitPattern: code)
    }

    private func duplicateProcessHandle() -> HANDLE? {
      lock.lock()
      defer { lock.unlock() }
      guard let process else { return nil }
      var duplicate: HANDLE?
      let duplicated = DuplicateHandle(
        GetCurrentProcess(),
        process,
        GetCurrentProcess(),
        &duplicate,
        0,
        false,
        DWORD(0x0000_0002)  // DUPLICATE_SAME_ACCESS
      )
      return duplicated ? duplicate : nil
    }

    func terminateTree(exitCode: UInt32) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard let job else { return false }
      if let process, WaitForSingleObject(process, 0) == WAIT_OBJECT_0 { return true }
      return TerminateJobObject(job, exitCode)
    }

    func close() {
      lock.lock()
      let currentProcess = process
      let currentJob = job
      process = nil
      job = nil
      lock.unlock()

      if let currentProcess, WaitForSingleObject(currentProcess, 0) == WAIT_TIMEOUT,
        let currentJob
      {
        TerminateJobObject(currentJob, 1)
        WaitForSingleObject(currentProcess, 5_000)
      }
      if let currentProcess { CloseHandle(currentProcess) }
      if let currentJob { CloseHandle(currentJob) }
    }
  }

  private final class RawPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var parentStorage: HANDLE?
    private var childStorage: HANDLE?
    let childReads: Bool

    var child: HANDLE {
      lock.lock()
      defer { lock.unlock() }
      return childStorage!
    }

    private init(parent: HANDLE, child: HANDLE, childReads: Bool) {
      parentStorage = parent
      childStorage = child
      self.childReads = childReads
    }

    static func make(childReads: Bool) throws -> RawPipe {
      var attributes = SECURITY_ATTRIBUTES()
      attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      attributes.bInheritHandle = true
      var readHandle: HANDLE?
      var writeHandle: HANDLE?
      guard CreatePipe(&readHandle, &writeHandle, &attributes, 0),
        let readHandle,
        let writeHandle
      else {
        throw WindowsJobProcessError.win32(operation: "CreatePipe", code: Int32(GetLastError()))
      }
      let parent = childReads ? writeHandle : readHandle
      let child = childReads ? readHandle : writeHandle
      guard SetHandleInformation(parent, DWORD(HANDLE_FLAG_INHERIT), 0) else {
        let code = Int32(GetLastError())
        CloseHandle(readHandle)
        CloseHandle(writeHandle)
        throw WindowsJobProcessError.win32(operation: "SetHandleInformation", code: code)
      }
      return RawPipe(parent: parent, child: child, childReads: childReads)
    }

    func closeChild() {
      lock.lock()
      let current = childStorage
      childStorage = nil
      lock.unlock()
      if let current { CloseHandle(current) }
    }

    func makeParentFileHandle(readOnly: Bool) throws -> FileHandle {
      lock.lock()
      guard let current = parentStorage else {
        lock.unlock()
        throw WindowsJobProcessError.invalidArguments
      }
      parentStorage = nil
      lock.unlock()

      let flags = readOnly ? (_O_RDONLY | _O_BINARY) : (_O_WRONLY | _O_BINARY)
      let descriptor = _open_osfhandle(intptr_t(bitPattern: current), flags)
      guard descriptor != -1 else {
        CloseHandle(current)
        throw WindowsJobProcessError.win32(operation: "_open_osfhandle", code: Int32(errno))
      }
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func closeAll() {
      lock.lock()
      let parent = parentStorage
      let child = childStorage
      parentStorage = nil
      childStorage = nil
      lock.unlock()
      if let parent { CloseHandle(parent) }
      if let child { CloseHandle(child) }
    }
  }

  private final class WideBuffer {
    let pointer: UnsafeMutablePointer<WCHAR>
    let count: Int

    init(_ value: String, appendNull: Bool = true) {
      var units = Array(value.utf16)
      if appendNull { units.append(0) }
      count = units.count
      pointer = .allocate(capacity: max(1, count))
      if units.isEmpty {
        pointer.initialize(to: 0)
      } else {
        units.withUnsafeBufferPointer { buffer in
          pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
        }
      }
    }

    deinit {
      pointer.deinitialize(count: max(1, count))
      pointer.deallocate()
    }
  }

  private final class ProcessAttributeList {
    let pointer: LPPROC_THREAD_ATTRIBUTE_LIST
    private let storage: UnsafeMutableRawBufferPointer
    private let handles: UnsafeMutablePointer<HANDLE>
    private let handleCount: Int

    init(handles values: [HANDLE]) throws {
      var byteCount = SIZE_T(0)
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &byteCount)
      storage = .allocate(byteCount: Int(byteCount), alignment: 16)
      pointer = LPPROC_THREAD_ATTRIBUTE_LIST(storage.baseAddress!)
      guard InitializeProcThreadAttributeList(pointer, 1, 0, &byteCount) else {
        storage.deallocate()
        throw WindowsJobProcessError.win32(
          operation: "InitializeProcThreadAttributeList",
          code: Int32(GetLastError())
        )
      }

      handleCount = values.count
      handles = .allocate(capacity: handleCount)
      values.withUnsafeBufferPointer { buffer in
        handles.initialize(from: buffer.baseAddress!, count: buffer.count)
      }
      let attribute = DWORD_PTR(0x0002_0002)  // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
      guard
        UpdateProcThreadAttribute(
          pointer,
          0,
          attribute,
          handles,
          SIZE_T(MemoryLayout<HANDLE>.stride * handleCount),
          nil,
          nil
        )
      else {
        let code = Int32(GetLastError())
        handles.deinitialize(count: handleCount)
        handles.deallocate()
        DeleteProcThreadAttributeList(pointer)
        storage.deallocate()
        throw WindowsJobProcessError.win32(
          operation: "UpdateProcThreadAttribute",
          code: code
        )
      }
    }

    deinit {
      handles.deinitialize(count: handleCount)
      handles.deallocate()
      DeleteProcThreadAttributeList(pointer)
      storage.deallocate()
    }
  }
#endif
