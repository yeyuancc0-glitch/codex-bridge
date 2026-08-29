import BridgeDomain
import BridgeServiceCore
import Foundation
import Logging

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

public struct DirectCommandSession: Sendable {
  public let sessionID: String
  public let projectID: ProjectID
  public let argv: [String]
  public let workingDirectory: String?
  public let startedAt: Date
  public let status: String
  public let exitCode: Int32?
  public let timedOut: Bool
  public let output: DirectCommandOutputBuffer
  public let processID: Int32?
  public let executionEnvironment: DirectCommandExecutionEnvironment

  public init(
    sessionID: String,
    projectID: ProjectID,
    argv: [String],
    workingDirectory: String?,
    startedAt: Date,
    status: String,
    exitCode: Int32? = nil,
    timedOut: Bool = false,
    output: DirectCommandOutputBuffer,
    processID: Int32?,
    executionEnvironment: DirectCommandExecutionEnvironment = DirectCommandExecutionEnvironment(
      bridgeSandbox: "unknown",
      sandboxExec: "unknown",
      nestedSandbox: "unknown",
      loopback: "unknown",
      childNetworkPolicy: "unknown"
    )
  ) {
    self.sessionID = sessionID
    self.projectID = projectID
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.startedAt = startedAt
    self.status = status
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.output = output
    self.processID = processID
    self.executionEnvironment = executionEnvironment
  }
}

public enum DirectCommandSessionError: Error, Equatable, Sendable {
  case sessionNotFound
  case projectBusy
  case invalidStdin
  case notRunning
}

public actor DirectCommandSessionManager {
  private struct TrackedPID: Sendable {
    let identity: DirectProcessIdentity
  }

  private let runner: DirectCommandRunner
  private let orphanPIDFileURL: URL?
  private let logger: Logger
  private let completedSessionTTL: TimeInterval
  private let maximumCompletedSessions: Int
  private let executionEnvironment: DirectExecutionEnvironmentCapabilities
  private var sessions: [String: DirectCommandSession] = [:]
  private var completedSessionAccess: [String: Date] = [:]
  private var activeProjectSession: [String: String] = [:]
  private var taskHandles: [String: Task<Void, Never>] = [:]
  private var processes: [String: DirectProcessLifetime] = [:]
  private var trackedPIDs: [String: TrackedPID] = [:]
  private var shutdown = false

  public init(
    runner: DirectCommandRunner = DirectCommandRunner(),
    orphanPIDFileURL: URL? = nil,
    logger: Logger = Logger(label: "com.codexbridge.direct.command"),
    completedSessionTTL: Duration = .seconds(600),
    maximumCompletedSessions: Int = 128,
    executionEnvironment: DirectExecutionEnvironmentCapabilities = .current()
  ) {
    self.runner = runner
    self.orphanPIDFileURL = orphanPIDFileURL
    self.logger = logger
    self.completedSessionTTL = max(0, Self.timeInterval(completedSessionTTL))
    self.maximumCompletedSessions = max(1, maximumCompletedSessions)
    self.executionEnvironment = executionEnvironment
    self.trackedPIDs = Self.loadTrackedPIDs(orphanPIDFileURL)
    Self.reapOrphans(trackedPIDs: trackedPIDs, logger: logger)
    Self.clearTrackedPIDs(orphanPIDFileURL)
  }

  public func snapshot(sessionID: String) -> DirectCommandSession? {
    pruneCompletedSessions()
    if let session = sessions[sessionID], session.status != "running" {
      completedSessionAccess[sessionID] = Date()
    }
    return sessions[sessionID]
  }

  public func activeSession(projectID: ProjectID) -> DirectCommandSession? {
    pruneCompletedSessions()
    guard let sessionID = activeProjectSession[projectID.rawValue] else { return nil }
    return sessions[sessionID]
  }

  public func allSessions() -> [DirectCommandSession] {
    pruneCompletedSessions()
    return sessions.values.sorted { $0.startedAt > $1.startedAt }
  }

  public func isBusy(projectID: ProjectID) -> Bool {
    pruneCompletedSessions()
    return activeProjectSession[projectID.rawValue] != nil
  }

  public func executionEnvironmentCapabilities() -> DirectExecutionEnvironmentCapabilities {
    executionEnvironment
  }

  public func launch(
    sessionID: String,
    projectID: ProjectID,
    argv: [String],
    workingDirectory: String?,
    requiresNetwork: Bool,
    usePTY: Bool,
    timeout: Duration? = nil,
    denyNetwork: Bool = false,
    onExit: (@Sendable () async -> Void)? = nil
  ) async throws -> DirectCommandSession {
    pruneCompletedSessions()
    guard !shutdown else { throw DirectCommandSessionError.notRunning }
    guard sessions[sessionID] == nil else { throw DirectCommandSessionError.sessionNotFound }
    guard activeProjectSession[projectID.rawValue] == nil else {
      throw DirectCommandSessionError.projectBusy
    }
    let output = DirectCommandOutputCollector(maximumBytes: runner.maximumOutputBytes)
    let process = try DirectProcessLifetime(
      argv: argv,
      workingDirectory: workingDirectory,
      environment: nil,
      usePTY: usePTY,
      output: output,
      denyNetwork: denyNetwork
    )
    let startedAt = Date()
    activeProjectSession[projectID.rawValue] = sessionID
    processes[sessionID] = process
    trackPID(sessionID: sessionID, pid: process.pid)
    let initial = DirectCommandSession(
      sessionID: sessionID,
      projectID: projectID,
      argv: argv,
      workingDirectory: workingDirectory,
      startedAt: startedAt,
      status: "running",
      output: DirectCommandOutputBuffer(head: "", tail: "", byteCount: 0, truncated: false),
      processID: process.pid,
      executionEnvironment: executionEnvironment.commandEnvironment(denyNetwork: denyNetwork)
    )
    sessions[sessionID] = initial

    let task = Task.detached { [weak self] in
      if let self {
        await self.monitorSession(
          sessionID: sessionID,
          projectID: projectID,
          argv: argv,
          workingDirectory: workingDirectory,
          process: process,
          output: output,
          timeout: timeout,
          onExit: onExit
        )
      }
    }
    taskHandles[sessionID] = task
    return initial
  }

  private func monitorSession(
    sessionID: String,
    projectID: ProjectID,
    argv: [String],
    workingDirectory: String?,
    process: DirectProcessLifetime,
    output: DirectCommandOutputCollector,
    timeout: Duration?,
    onExit: (@Sendable () async -> Void)?
  ) async {
    let result = await runner.monitor(
      process: process,
      sessionID: sessionID,
      output: output,
      timeout: timeout
    )
    guard !shutdown else { return }
    let status: String
    let exitCode: Int32?
    switch result.termination {
    case .exited(let code):
      exitCode = code
      status = result.timedOut ? "timed_out" : "ended"
    case .killed:
      exitCode = nil
      status = result.timedOut ? "timed_out" : "cancelled"
    case .notStarted:
      exitCode = nil
      status = "failed"
    }
    sessions[sessionID] = DirectCommandSession(
      sessionID: sessionID,
      projectID: projectID,
      argv: argv,
      workingDirectory: workingDirectory,
      startedAt: sessions[sessionID]?.startedAt ?? Date(),
      status: status,
      exitCode: exitCode,
      timedOut: result.timedOut,
      output: result.output,
      processID: nil,
      executionEnvironment: sessions[sessionID]?.executionEnvironment
        ?? executionEnvironment.commandEnvironment(denyNetwork: false)
    )
    untrackPID(sessionID: sessionID)
    processes[sessionID] = nil
    activeProjectSession[projectID.rawValue] = nil
    taskHandles[sessionID] = nil
    completedSessionAccess[sessionID] = Date()
    pruneCompletedSessions()
    if let onExit {
      await onExit()
    }
  }

  public func writeStdin(
    sessionID: String,
    data: Data,
    closeStdin: Bool = false
  ) async throws {
    guard let session = sessions[sessionID], session.status == "running" else {
      throw DirectCommandSessionError.notRunning
    }
    guard !data.isEmpty || closeStdin, data.count <= 64 * 1_024 else {
      throw DirectCommandSessionError.invalidStdin
    }
    guard let process = processes[sessionID] else {
      throw DirectCommandSessionError.notRunning
    }
    if !data.isEmpty {
      try process.writeStdin(data)
    }
    if closeStdin {
      process.closeStdin()
    }
  }

  public func interrupt(sessionID: String) async throws {
    guard let session = sessions[sessionID], session.status == "running" else {
      throw DirectCommandSessionError.notRunning
    }
    guard let process = processes[sessionID] else {
      throw DirectCommandSessionError.notRunning
    }
    guard process.terminateAndWait(gracePeriod: runner.gracePeriod) != nil else {
      throw DirectCommandSessionError.notRunning
    }
  }

  public func cancelAll() async {
    shutdown = true
    let active = processes
    for (sessionID, process) in active {
      let termination = process.terminateAndWait(gracePeriod: runner.gracePeriod)
      if termination == nil {
        logger.error("Unable to reap direct command session \(sessionID) pid \(process.pid)")
        continue
      }
      untrackPID(sessionID: sessionID)
    }
    for task in taskHandles.values {
      task.cancel()
    }
    activeProjectSession = [:]
    taskHandles.removeAll()
    processes.removeAll()
    sessions.removeAll()
    completedSessionAccess.removeAll()
  }

  private func trackPID(sessionID: String, pid: Int32) {
    guard let identity = processes[sessionID]?.identity, identity.pid == pid else { return }
    trackedPIDs[sessionID] = TrackedPID(identity: identity)
    persistTrackedPIDs()
  }

  private func untrackPID(sessionID: String) {
    guard trackedPIDs.removeValue(forKey: sessionID) != nil else { return }
    persistTrackedPIDs()
  }

  private func persistTrackedPIDs() {
    guard let url = orphanPIDFileURL else { return }
    let lines = trackedPIDs.map { sessionID, tracked in
      let identity = tracked.identity
      return
        "\(sessionID)\t\(identity.pid)\t\(identity.startTimeMicros)\t\(identity.processGroupID)"
    }.sorted().joined(separator: "\n")
    try? Data(lines.utf8).write(to: url, options: .atomic)
  }

  private static func loadTrackedPIDs(_ url: URL?) -> [String: TrackedPID] {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: TrackedPID] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "\t")
      guard parts.count == 4,
        let pid = Int32(parts[1]),
        let startTimeMicros = Int64(parts[2]),
        let processGroupID = Int32(parts[3]),
        pid > 1,
        processGroupID == pid
      else { continue }
      result[String(parts[0])] = TrackedPID(
        identity: DirectProcessIdentity(
          pid: pid,
          startTimeMicros: startTimeMicros,
          processGroupID: processGroupID
        )
      )
    }
    return result
  }

  private static func reapOrphans(trackedPIDs: [String: TrackedPID], logger: Logger) {
    for (sessionID, tracked) in trackedPIDs {
      let identity = tracked.identity
      guard DirectProcessLifetime.matchesCurrentProcess(identity) else { continue }
      #if os(Windows)
        // Windows has no process groups; terminate the tracked process itself.
        if let handle = OpenProcess(
          DWORD(PROCESS_TERMINATE),
          false,
          DWORD(UInt32(bitPattern: identity.pid))
        ) {
          _ = TerminateProcess(handle, 1)
          CloseHandle(handle)
        }
      #else
        _ = Darwin.kill(-identity.processGroupID, SIGKILL)
      #endif
      logger.warning(
        "Reaped orphan direct command session \(sessionID) pid \(identity.pid)"
      )
    }
  }

  private static func clearTrackedPIDs(_ url: URL?) {
    guard let url else { return }
    try? Data().write(to: url, options: .atomic)
  }

  private func pruneCompletedSessions(now: Date = Date()) {
    let expired = completedSessionAccess.compactMap { sessionID, lastAccess in
      now.timeIntervalSince(lastAccess) >= completedSessionTTL ? sessionID : nil
    }
    for sessionID in expired {
      completedSessionAccess[sessionID] = nil
      sessions[sessionID] = nil
    }

    let completed = completedSessionAccess.keys.sorted {
      (completedSessionAccess[$0] ?? .distantPast)
        < (completedSessionAccess[$1] ?? .distantPast)
    }
    guard completed.count > maximumCompletedSessions else { return }
    for sessionID in completed.prefix(completed.count - maximumCompletedSessions) {
      completedSessionAccess[sessionID] = nil
      sessions[sessionID] = nil
    }
  }

  private static func timeInterval(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
