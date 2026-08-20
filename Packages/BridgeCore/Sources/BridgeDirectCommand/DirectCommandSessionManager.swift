import BridgeDomain
import BridgeServiceCore
import Foundation
import Logging

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
    processID: Int32?
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
  }
}

public enum DirectCommandSessionError: Error, Equatable, Sendable {
  case sessionNotFound
  case projectBusy
  case invalidStdin
  case notRunning
}

public actor DirectCommandSessionManager {
  private let runner: DirectCommandRunner
  private let orphanPIDFileURL: URL?
  private let logger: Logger
  private var sessions: [String: DirectCommandSession] = [:]
  private var activeProjectSession: [String: String] = [:]
  private var taskHandles: [String: Task<Void, Never>] = [:]
  private var processes: [String: DirectProcessLifetime] = [:]
  private var trackedPIDs: [String: Int32] = [:]
  private var shutdown = false

  public init(
    runner: DirectCommandRunner = DirectCommandRunner(),
    orphanPIDFileURL: URL? = nil,
    logger: Logger = Logger(label: "com.codexbridge.direct.command")
  ) {
    self.runner = runner
    self.orphanPIDFileURL = orphanPIDFileURL
    self.logger = logger
    self.trackedPIDs = Self.loadTrackedPIDs(orphanPIDFileURL)
    Self.reapOrphans(trackedPIDs: trackedPIDs, logger: logger)
    Self.clearTrackedPIDs(orphanPIDFileURL)
  }

  public func snapshot(sessionID: String) -> DirectCommandSession? {
    sessions[sessionID]
  }

  public func activeSession(projectID: ProjectID) -> DirectCommandSession? {
    guard let sessionID = activeProjectSession[projectID.rawValue] else { return nil }
    return sessions[sessionID]
  }

  public func allSessions() -> [DirectCommandSession] {
    sessions.values.sorted { $0.startedAt > $1.startedAt }
  }

  public func isBusy(projectID: ProjectID) -> Bool {
    activeProjectSession[projectID.rawValue] != nil
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
      processID: process.pid
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
      processID: nil
    )
    untrackPID(sessionID: sessionID)
    processes[sessionID] = nil
    activeProjectSession[projectID.rawValue] = nil
    taskHandles[sessionID] = nil
    if let onExit {
      await onExit()
    }
  }

  public func writeStdin(sessionID: String, data: Data) async throws {
    guard let session = sessions[sessionID], session.status == "running" else {
      throw DirectCommandSessionError.notRunning
    }
    guard !data.isEmpty, data.count <= 64 * 1_024 else {
      throw DirectCommandSessionError.invalidStdin
    }
    guard let process = processes[sessionID] else {
      throw DirectCommandSessionError.notRunning
    }
    try process.writeStdin(data)
  }

  public func interrupt(sessionID: String) async throws {
    guard let session = sessions[sessionID], session.status == "running" else {
      throw DirectCommandSessionError.notRunning
    }
    guard let process = processes[sessionID] else {
      throw DirectCommandSessionError.notRunning
    }
    process.terminateGroup()
  }

  public func cancelAll() async {
    shutdown = true
    for process in processes.values {
      process.terminateGroup()
    }
    for sessionID in sessions.keys {
      untrackPID(sessionID: sessionID)
    }
    activeProjectSession = [:]
    taskHandles.removeAll()
    processes.removeAll()
    sessions.removeAll()
  }

  private func trackPID(sessionID: String, pid: Int32) {
    trackedPIDs[sessionID] = pid
    persistTrackedPIDs()
  }

  private func untrackPID(sessionID: String) {
    guard trackedPIDs.removeValue(forKey: sessionID) != nil else { return }
    persistTrackedPIDs()
  }

  private func persistTrackedPIDs() {
    guard let url = orphanPIDFileURL else { return }
    let lines = trackedPIDs.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    try? Data(lines.utf8).write(to: url, options: .atomic)
  }

  private static func loadTrackedPIDs(_ url: URL?) -> [String: Int32] {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: Int32] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "\t")
      guard parts.count == 2, let pid = Int32(parts[1]) else { continue }
      result[String(parts[0])] = pid
    }
    return result
  }

  private static func reapOrphans(trackedPIDs: [String: Int32], logger: Logger) {
    for (sessionID, pid) in trackedPIDs {
      guard pid > 1 else { continue }
      let exists = kill(pid, 0) == 0
      if exists {
        _ = Darwin.kill(-pid, SIGKILL)
        logger.warning("Reaped orphan direct command session \(sessionID) pid \(pid)")
      }
    }
  }

  private static func clearTrackedPIDs(_ url: URL?) {
    guard let url else { return }
    try? Data().write(to: url, options: .atomic)
  }
}
