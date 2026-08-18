import BridgeDirectCommand
import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation
import XCTest

final class DirectCommandPolicyTests: XCTestCase {
  private func project(
    mode: ServiceDirectCommandMode,
    write: ProjectPermission = .requiresLocalApproval,
    network: ProjectPermission = .denied,
    commands: [ServiceWorkspaceCommand] = []
  ) throws -> ServiceProjectRecord {
    try ServiceProjectRecord(
      id: ProjectID(rawValue: "prj-policy"),
      name: "Policy",
      root: ServiceRootIdentity(capturing: FileManager.default.temporaryDirectory),
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: write,
        network: network
      ),
      directCommandMode: mode,
      workspaceCommands: commands,
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  func testDeniedModeRejectsEverything() throws {
    let policy = DirectCommandPolicy()
    let result = policy.resolve(
      project: try project(mode: .denied),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: nil,
        argv: ["git", "status"]
      )
    )
    XCTAssertEqual(result.reason, .commandModeDenied)
    XCTAssertFalse(result.allowed)
  }

  func testRegisteredModeRejectsUnregisteredCommand() throws {
    let policy = DirectCommandPolicy()
    let result = policy.resolve(
      project: try project(mode: .registered),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: nil,
        argv: ["git", "status"]
      )
    )
    XCTAssertEqual(result.reason, .commandNotRegistered)
  }

  func testRegisteredModeAllowsRegisteredCommandByID() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-test",
      name: "Tests",
      executable: "Scripts/with-xcode.sh",
      arguments: ["swift", "test"],
      requiresNetwork: false
    )
    let result = policy.resolve(
      project: try project(
        mode: .registered,
        write: .allowed,
        commands: [command]
      ),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-test",
        argv: []
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertFalse(result.requiresApproval)
    XCTAssertEqual(result.argv, ["Scripts/with-xcode.sh", "swift", "test"])
  }

  func testRegisteredModeRejectsMismatchedArgv() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-test",
      name: "Tests",
      executable: "Scripts/with-xcode.sh",
      arguments: ["swift", "test"],
      requiresNetwork: false
    )
    let result = policy.resolve(
      project: try project(mode: .registered, commands: [command]),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-test",
        argv: ["rm", "-rf"]
      )
    )
    XCTAssertEqual(result.reason, .invalidArguments)
  }

  func testSafeModeAllowsBuiltInGit() throws {
    let policy = DirectCommandPolicy()
    let result = policy.resolve(
      project: try project(mode: .safe),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: nil,
        argv: ["git", "status"]
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertEqual(result.argv, ["git", "status"])
  }

  func testSafeModeRejectsUnsafeProgram() throws {
    let policy = DirectCommandPolicy()
    let result = policy.resolve(
      project: try project(mode: .safe),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: nil,
        argv: ["/bin/rm", "-rf", "."]
      )
    )
    XCTAssertEqual(result.reason, .commandNotRegistered)
  }

  func testNetworkDeniedRejectsNetworkCommand() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-pull",
      name: "Pull",
      executable: "git",
      arguments: ["pull"],
      requiresNetwork: true
    )
    let result = policy.resolve(
      project: try project(mode: .registered, commands: [command]),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-pull",
        argv: []
      )
    )
    XCTAssertEqual(result.reason, .networkNotAllowed)
  }

  func testElevatedRiskRequiresApproval() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-deploy",
      name: "Deploy",
      executable: "make",
      arguments: ["deploy"],
      requiresNetwork: false,
      risk: .elevated
    )
    let result = policy.resolve(
      project: try project(mode: .registered, commands: [command]),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-deploy",
        argv: []
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertTrue(result.requiresApproval)
  }

  func testWriteRequiresLocalApprovalMakesNormalCommandRequireApproval() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-build",
      name: "Build",
      executable: "swift",
      arguments: ["build"],
      requiresNetwork: false
    )
    let result = policy.resolve(
      project: try project(mode: .registered, commands: [command]),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-build",
        argv: []
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertTrue(result.requiresApproval)
  }

  func testWriteAllowedRemovesApprovalRequirement() throws {
    let policy = DirectCommandPolicy()
    let command = try ServiceWorkspaceCommand(
      id: "wcmd-build",
      name: "Build",
      executable: "swift",
      arguments: ["build"],
      requiresNetwork: false
    )
    let result = policy.resolve(
      project: try project(
        mode: .registered,
        write: .allowed,
        commands: [command]
      ),
      request: DirectCommandRequest(
        projectID: ProjectID(rawValue: "prj-policy"),
        commandID: "wcmd-build",
        argv: []
      )
    )
    XCTAssertTrue(result.allowed)
    XCTAssertFalse(result.requiresApproval)
  }
}

final class DirectCommandOutputCollectorTests: XCTestCase {
  func testCollectorBoundsAndReportsTruncation() {
    let collector = DirectCommandOutputCollector(maximumBytes: 256)
    collector.append(Data(String(repeating: "a", count: 200).utf8))
    var snapshot = collector.snapshot()
    XCTAssertEqual(snapshot.byteCount, 200)
    XCTAssertFalse(snapshot.truncated)

    collector.append(Data(String(repeating: "b", count: 200).utf8))
    snapshot = collector.snapshot()
    XCTAssertEqual(snapshot.byteCount, 256)
    XCTAssertTrue(snapshot.truncated)
    XCTAssertTrue(snapshot.tail.hasSuffix("b"))
  }

  func testHeadAndTailAreBounded() {
    let collector = DirectCommandOutputCollector(maximumBytes: 1_024)
    collector.append(Data(String(repeating: "x", count: 1_024).utf8))
    let snapshot = collector.snapshot()
    XCTAssertLessThanOrEqual(snapshot.head.utf8.count, 4_096)
    XCTAssertLessThanOrEqual(snapshot.tail.utf8.count, 32 * 1_024)
  }
}

final class DirectCommandSessionManagerTests: XCTestCase {
  func testRunsCommandAndCapturesOutput() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "direct-command-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .seconds(10)),
      orphanPIDFileURL: root.appending(path: "orphan-pids.txt")
    )
    let projectID = ProjectID(rawValue: "prj-cmd")
    let session = try await manager.launch(
      sessionID: "dcmd-1",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "echo hello-from-direct-command"],
      workingDirectory: root.path,
      requiresNetwork: false,
      usePTY: false
    )
    XCTAssertEqual(session.status, "running")

    var deadline = Date().addingTimeInterval(10)
    var finished: DirectCommandSession?
    while Date() < deadline {
      if let current = await manager.snapshot(sessionID: "dcmd-1"), current.status == "ended" {
        finished = current
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let result = try XCTUnwrap(finished)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.output.tail.contains("hello-from-direct-command"))
  }

  func testProjectBusyRejectsSecondConcurrentSession() async throws {
    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .seconds(30))
    )
    let projectID = ProjectID(rawValue: "prj-busy")
    _ = try await manager.launch(
      sessionID: "dcmd-1",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "sleep 5"],
      workingDirectory: nil,
      requiresNetwork: false,
      usePTY: false
    )
    do {
      _ = try await manager.launch(
        sessionID: "dcmd-2",
        projectID: projectID,
        argv: ["/bin/sh", "-c", "echo second"],
        workingDirectory: nil,
        requiresNetwork: false,
        usePTY: false
      )
      XCTFail("Expected projectBusy")
    } catch let error as DirectCommandSessionError {
      XCTAssertEqual(error, .projectBusy)
    }
    await manager.cancelAll()
  }

  func testInterruptCancelsRunningCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "direct-command-interrupt-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .seconds(60))
    )
    let projectID = ProjectID(rawValue: "prj-interrupt")
    _ = try await manager.launch(
      sessionID: "dcmd-interrupt",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "sleep 30"],
      workingDirectory: root.path,
      requiresNetwork: false,
      usePTY: false
    )
    try await manager.interrupt(sessionID: "dcmd-interrupt")

    var deadline = Date().addingTimeInterval(10)
    var finished: DirectCommandSession?
    while Date() < deadline {
      if let current = await manager.snapshot(sessionID: "dcmd-interrupt"),
        current.status == "cancelled" || current.status == "ended"
      {
        finished = current
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let result = try XCTUnwrap(finished)
    XCTAssertTrue(result.status == "cancelled" || result.status == "ended")
    XCTAssertNil(result.exitCode)
    await manager.cancelAll()
  }

  func testTimeoutMarksSessionTimedOut() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "direct-command-timeout-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .milliseconds(300))
    )
    let projectID = ProjectID(rawValue: "prj-timeout")
    _ = try await manager.launch(
      sessionID: "dcmd-timeout",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "sleep 30"],
      workingDirectory: root.path,
      requiresNetwork: false,
      usePTY: false,
      timeout: .milliseconds(300)
    )

    var deadline = Date().addingTimeInterval(10)
    var finished: DirectCommandSession?
    while Date() < deadline {
      if let current = await manager.snapshot(sessionID: "dcmd-timeout"),
        current.status == "timed_out"
      {
        finished = current
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let result = try XCTUnwrap(finished)
    XCTAssertTrue(result.timedOut)
    XCTAssertEqual(result.status, "timed_out")
    await manager.cancelAll()
  }

  func testCancelAllTerminatesRunningProcesses() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "direct-command-cancelall-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .seconds(60))
    )
    let projectID = ProjectID(rawValue: "prj-cancel")
    let session = try await manager.launch(
      sessionID: "dcmd-cancel",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "sleep 30"],
      workingDirectory: root.path,
      requiresNetwork: false,
      usePTY: false
    )
    let pid = try XCTUnwrap(session.processID)
    await manager.cancelAll()
    var deadline = Date().addingTimeInterval(5)
    var reaped = false
    while Date() < deadline {
      if kill(pid, 0) != 0 {
        reaped = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(reaped)
  }

  func testManagerInitReapsOrphanProcessesAfterServiceCrash() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "direct-command-orphan-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let orphanPIDFile = root.appending(path: "orphan-pids.txt")
    let survivor = Process()
    survivor.executableURL = URL(fileURLWithPath: "/bin/sh")
    survivor.arguments = ["-c", "trap 'exit 0' TERM; while true; do sleep 1; done"]
    survivor.standardOutput = FileHandle.nullDevice
    survivor.standardError = FileHandle.nullDevice
    survivor.standardInput = FileHandle.nullDevice
    try survivor.run()
    let survivorPID = survivor.processIdentifier
    defer { _ = Darwin.kill(-survivorPID, SIGKILL) }

    let spawned = Process()
    spawned.executableURL = URL(fileURLWithPath: "/bin/sh")
    spawned.arguments = ["-c", "trap 'exit 0' TERM; while true; do sleep 1; done"]
    spawned.standardOutput = FileHandle.nullDevice
    spawned.standardError = FileHandle.nullDevice
    spawned.standardInput = FileHandle.nullDevice
    try spawned.run()
    let orphanPID = spawned.processIdentifier
    _ = Darwin.setpgid(orphanPID, orphanPID)
    try Data("orphan-session\t\(orphanPID)\n".utf8).write(to: orphanPIDFile, options: .atomic)

    // Service restarts and constructs a new manager; it must reap the orphaned process group.
    let manager = DirectCommandSessionManager(
      runner: DirectCommandRunner(defaultTimeout: .seconds(60)),
      orphanPIDFileURL: orphanPIDFile
    )
    defer { Task { await manager.cancelAll() } }
    let survivorAlive = kill(survivorPID, 0) == 0
    XCTAssertTrue(survivorAlive, "unrelated process must be left alone")

    var deadline = Date().addingTimeInterval(5)
    var reaped = false
    while Date() < deadline {
      if kill(orphanPID, 0) != 0 {
        reaped = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(reaped, "orphaned direct command process must be reaped on restart")
  }
}
