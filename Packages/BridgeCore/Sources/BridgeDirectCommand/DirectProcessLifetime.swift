import BridgeProcess
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
  private let process: ManagedStdioProcess

  public var identity: DirectProcessIdentity? {
    process.identity.map(Self.directIdentity)
  }

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String]?,
    usePTY: Bool,
    output: DirectCommandOutputCollector,
    denyNetwork: Bool = false
  ) throws {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128, !usePTY else {
      throw DirectProcessError.invalidArgument
    }
    let launchArgv: [String]
    if denyNetwork {
      guard Self.sandboxExecAvailable else { throw DirectProcessError.sandboxUnavailable }
      launchArgv = [Self.sandboxExecPath, "-p", Self.denyNetworkProfile, "--"] + argv
    } else {
      launchArgv = argv
    }
    let environment = Self.defaultEnvironment(overrides: environment)
    do {
      process = try ManagedStdioProcess(
        argv: launchArgv,
        workingDirectory: workingDirectory,
        environment: environment,
        mergeStandardError: true,
        onStandardOutput: { output.append($0) }
      )
    } catch let error as ManagedProcessError {
      throw Self.directError(error)
    }
    pid = process.pid
  }

  public func writeStdin(_ data: Data) throws {
    do {
      try process.writeStdin(data)
    } catch {
      throw DirectProcessError.stdinUnavailable
    }
  }

  public func closeStdin() {
    process.closeStdin()
  }

  public func terminateGroup() {
    process.terminateGroup()
  }

  public func killGroup() {
    process.killGroup()
  }

  public var isRunning: Bool {
    process.isRunning
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200))
    -> DirectProcessTermination?
  {
    process.reapIfExited(gracePeriod: gracePeriod).map(Self.directTermination)
  }

  public func waitForExit(timeout: Duration) -> DirectProcessTermination? {
    process.waitForExit(timeout: timeout).map(Self.directTermination)
  }

  public func terminateAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> DirectProcessTermination? {
    process.terminateAndWait(gracePeriod: gracePeriod, killWait: killWait)
      .map(Self.directTermination)
  }

  public func pollOutput() {}

  public func drainRemainingOutput() {
    process.drainRemainingOutput()
  }

  public func close() {
    process.close()
  }

  public static func identity(of processID: Int32) -> DirectProcessIdentity? {
    ManagedStdioProcess.identity(of: processID).map(directIdentity)
  }

  public static func matchesCurrentProcess(_ identity: DirectProcessIdentity) -> Bool {
    ManagedStdioProcess.matchesCurrentProcess(
      ManagedProcessIdentity(
        pid: identity.pid,
        startTimeMicros: identity.startTimeMicros,
        processGroupID: identity.processGroupID
      )
    )
  }

  private static func directIdentity(_ identity: ManagedProcessIdentity) -> DirectProcessIdentity {
    DirectProcessIdentity(
      pid: identity.pid,
      startTimeMicros: identity.startTimeMicros,
      processGroupID: identity.processGroupID
    )
  }

  private static func directTermination(
    _ termination: ManagedProcessTermination
  ) -> DirectProcessTermination {
    switch termination {
    case .exited(let code): .exited(code)
    case .killed(let signal): .killed(signal)
    case .notStarted: .notStarted
    }
  }

  private static func directError(_ error: ManagedProcessError) -> DirectProcessError {
    switch error {
    case .invalidArgument: .invalidArgument
    case .processLaunchFailed(let code): .processLaunchFailed(code)
    case .stdinUnavailable: .stdinUnavailable
    }
  }

  private static let sandboxExecPath = "/usr/bin/sandbox-exec"
  private static let sandboxExecAvailable = FileManager.default.isExecutableFile(
    atPath: sandboxExecPath
  )
  private static let denyNetworkProfile = "(version 1)(allow default)(deny network*)"

  public static func defaultEnvironment(overrides: [String: String]? = nil) -> [String: String] {
    var environment: [String: String] = [:]
    let processEnv = ProcessInfo.processInfo.environment
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL"] {
      if let value = processEnv[key] {
        environment[key] = value
      }
    }
    if environment["HOME"] == nil {
      environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    }
    if environment["TMPDIR"] == nil {
      environment["TMPDIR"] = NSTemporaryDirectory()
    }
    let trustedDirectories = [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    if let currentPath = processEnv["PATH"], !currentPath.isEmpty {
      let existing = currentPath.split(separator: ":").map(String.init)
      var combined = existing
      for dir in trustedDirectories where !combined.contains(dir) {
        combined.append(dir)
      }
      environment["PATH"] = combined.joined(separator: ":")
    } else {
      environment["PATH"] = trustedDirectories.joined(separator: ":")
    }
    if let overrides {
      environment.merge(overrides) { _, replacement in replacement }
    }
    return environment
  }
}
