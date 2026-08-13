import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeVerification

final class VerificationRunnerTests: XCTestCase {
  func testRunsOnlyRegisteredCommandByIndexInExactWorkingDirectory() async throws {
    let scratch = try ScratchDirectory(label: "registered-command")
    defer { scratch.remove() }
    let command = try VerificationCommand(
      executable: "/usr/bin/touch",
      arguments: ["verified-marker"]
    )
    let project = try makeProject(root: scratch.url, commands: [command])

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .passed)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.required)
    XCTAssertEqual(result.commandIndex, 0)
    XCTAssertEqual(result.commandID, VerificationCommandIdentifier(command: command))
    XCTAssertEqual(result.executableName, "touch")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: scratch.url.appending(path: "verified-marker").path
      )
    )
  }

  func testStableIdentifierSelectsRegisteredCommandAndUnknownIdentifierFails() async throws {
    let scratch = try ScratchDirectory(label: "stable-id")
    defer { scratch.remove() }
    let first = try VerificationCommand(executable: "/usr/bin/false")
    let second = try VerificationCommand(executable: "/usr/bin/true")
    let project = try makeProject(root: scratch.url, commands: [first, second])
    let identifier = VerificationCommandIdentifier(command: second)

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .identifier(identifier),
      required: false,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .passed)
    XCTAssertEqual(result.commandIndex, 1)
    let unknown = try XCTUnwrap(
      VerificationCommandIdentifier(
        rawValue: "vcmd_" + String(repeating: "0", count: 64)
      )
    )
    do {
      _ = try await VerificationRunner().run(
        project: project,
        workingDirectory: project.primaryRoot,
        command: .identifier(unknown),
        required: false
      )
      XCTFail("Expected an unregistered command identifier to fail")
    } catch {
      XCTAssertEqual(error as? VerificationRunnerError, .unknownCommandIdentifier)
    }
  }

  func testFailureReturnsBoundedStructuralSummaryWithoutRawOutput() async throws {
    let scratch = try ScratchDirectory(label: "summary")
    defer { scratch.remove() }
    let marker = "bridge-verification-sensitive-fixture"
    let command = try VerificationCommand(
      executable: "/usr/bin/printf",
      arguments: [marker]
    )
    let project = try makeProject(root: scratch.url, commands: [command])

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: false,
      authorization: .localUserApproved
    )
    let encoded = try JSONEncoder().encode(result)

    XCTAssertEqual(result.status, .passed)
    XCTAssertEqual(result.standardOutput.capturedByteCount, marker.utf8.count)
    XCTAssertEqual(result.standardOutput.lineCount, 1)
    XCTAssertEqual(result.standardOutput.sha256.count, 64)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(marker))
  }

  func testNonzeroExitIsReportedAsFailedWithExactExitCode() async throws {
    let scratch = try ScratchDirectory(label: "nonzero-exit")
    defer { scratch.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/false")
    let project = try makeProject(root: scratch.url, commands: [command])

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .failed)
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.required)
  }

  func testIdentifierDecoderRejectsNonASCIIAndUppercaseDigests() throws {
    let decoder = JSONDecoder()
    let uppercase = Data(("\"vcmd_" + String(repeating: "A", count: 64) + "\"").utf8)
    let fullwidth = Data(("\"vcmd_" + String(repeating: "１", count: 64) + "\"").utf8)

    XCTAssertThrowsError(try decoder.decode(VerificationCommandIdentifier.self, from: uppercase))
    XCTAssertThrowsError(try decoder.decode(VerificationCommandIdentifier.self, from: fullwidth))
  }

  func testLocalExecutionRequiresExplicitUserApproval() async throws {
    let scratch = try ScratchDirectory(label: "approval-required")
    defer { scratch.remove() }
    let marker = scratch.url.appending(path: "must-not-run")
    let command = try VerificationCommand(
      executable: "/usr/bin/touch",
      arguments: [marker.lastPathComponent]
    )
    let project = try makeProject(root: scratch.url, commands: [command])

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true
    )

    XCTAssertEqual(result.status, .localApprovalRequired)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testNetworkDeniedProjectDoesNotLaunchKnownNetworkCommand() async throws {
    let scratch = try ScratchDirectory(label: "network-denied")
    defer { scratch.remove() }
    let marker = scratch.url.appending(path: "network-marker")
    let command = try VerificationCommand(
      executable: "/usr/bin/curl",
      arguments: ["--output", marker.path, "file:///dev/null"]
    )
    let project = try makeProject(
      root: scratch.url,
      commands: [command],
      policy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .denied)
    )

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .policyDenied)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testLocalApprovalCannotRunNetworkCommandWhenProjectAllowsNetwork() async throws {
    let scratch = try ScratchDirectory(label: "network-allowed")
    defer { scratch.remove() }
    let marker = scratch.url.appending(path: "network-marker")
    let command = try VerificationCommand(
      executable: "/usr/bin/curl",
      arguments: ["--output", marker.path, "file:///dev/null"]
    )
    let project = try makeProject(
      root: scratch.url,
      commands: [command],
      policy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed)
    )

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .policyDenied)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testLocalApprovalCannotRunPackageInstallerWhenProjectAllowsWrites() async throws {
    let scratch = try ScratchDirectory(label: "package-install")
    defer { scratch.remove() }
    let marker = scratch.url.appending(path: "package-marker")
    let executable = scratch.url.appending(path: "npm")
    try Data("#!/bin/sh\ntouch package-marker\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let command = try VerificationCommand(
      executable: executable.path,
      arguments: ["install"]
    )
    let project = try makeProject(
      root: scratch.url,
      commands: [command],
      policy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed)
    )

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .policyDenied)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testLocalApprovalCannotOverrideUnsupportedShellWrapper() async throws {
    let scratch = try ScratchDirectory(label: "shell-wrapper")
    defer { scratch.remove() }
    let marker = scratch.url.appending(path: "shell-marker")
    let command = try VerificationCommand(
      executable: "/bin/sh",
      arguments: ["-c", "touch shell-marker"]
    )
    let project = try makeProject(
      root: scratch.url,
      commands: [command],
      policy: ProjectAccessPolicy(read: .allowed, write: .allowed, network: .denied)
    )

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .policyDenied)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testReplacedRootFailsClosedWithoutWritingReplacement() async throws {
    let scratch = try ScratchDirectory(label: "root-replaced")
    defer { scratch.remove() }
    let root = scratch.url.appending(path: "project", directoryHint: .isDirectory)
    let moved = scratch.url.appending(path: "moved", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let command = try VerificationCommand(
      executable: "/usr/bin/touch",
      arguments: ["must-not-exist"]
    )
    let project = try makeProject(root: root, commands: [command])
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .rootUnavailable)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appending(path: "must-not-exist").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: moved.appending(path: "must-not-exist").path)
    )
  }

  func testOutputFloodIsTerminatedAtConfiguredLimit() async throws {
    let scratch = try ScratchDirectory(label: "output-limit")
    defer { scratch.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/yes", arguments: ["bounded"])
    let project = try makeProject(root: scratch.url, commands: [command])
    let runner = VerificationRunner(
      configuration: .init(
        timeout: .seconds(2),
        terminationGracePeriod: .milliseconds(20),
        maximumStandardOutputBytes: 64,
        maximumStandardErrorBytes: 32
      )
    )

    let result = try await runner.run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .outputLimitExceeded)
    XCTAssertEqual(result.standardOutput.capturedByteCount, 64)
    XCTAssertTrue(result.standardOutput.truncated)
  }

  func testTimeoutTerminatesAndReapsProcess() async throws {
    let scratch = try ScratchDirectory(label: "timeout")
    defer { scratch.remove() }
    let command = try VerificationCommand(executable: "/bin/sleep", arguments: ["5"])
    let project = try makeProject(root: scratch.url, commands: [command])
    let runner = VerificationRunner(
      configuration: .init(
        timeout: .milliseconds(30),
        terminationGracePeriod: .zero
      )
    )
    let start = ContinuousClock().now

    let result = try await runner.run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: .localUserApproved
    )

    XCTAssertEqual(result.status, .timedOut)
    XCTAssertLessThan(start.duration(to: ContinuousClock().now), .seconds(2))
  }

  func testCancellationTerminatesAndReapsProcess() async throws {
    let scratch = try ScratchDirectory(label: "cancel")
    defer { scratch.remove() }
    let command = try VerificationCommand(executable: "/bin/sleep", arguments: ["5"])
    let project = try makeProject(root: scratch.url, commands: [command])
    let runner = VerificationRunner(
      configuration: .init(
        timeout: .seconds(3),
        terminationGracePeriod: .milliseconds(20)
      )
    )
    let task = Task {
      try await runner.run(
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        required: false,
        authorization: .localUserApproved
      )
    }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()

    let result = try await task.value

    XCTAssertEqual(result.status, .cancelled)
    XCTAssertFalse(result.required)
  }

  func testForeignWorkingDirectoryIsRejectedBeforeLaunch() async throws {
    let scratch = try ScratchDirectory(label: "foreign-root")
    defer { scratch.remove() }
    let projectRoot = scratch.url.appending(path: "project", directoryHint: .isDirectory)
    let foreignRoot = scratch.url.appending(path: "foreign", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: false)
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try makeProject(root: projectRoot, commands: [command])

    do {
      _ = try await VerificationRunner().run(
        project: project,
        workingDirectory: RegisteredRoot(capturing: foreignRoot),
        command: .index(0),
        required: false
      )
      XCTFail("Expected a foreign working directory to fail")
    } catch {
      XCTAssertEqual(error as? VerificationRunnerError, .workingDirectoryNotRegistered)
    }
  }

  func testNonAbsoluteExecutableIsNeverResolvedThroughPath() async throws {
    let scratch = try ScratchDirectory(label: "relative-executable")
    defer { scratch.remove() }
    let command = try VerificationCommand(executable: "touch", arguments: ["must-not-exist"])
    let project = try makeProject(root: scratch.url, commands: [command])

    let result = try await VerificationRunner().run(
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true
    )

    XCTAssertEqual(result.status, .policyDenied)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: scratch.url.appending(path: "must-not-exist").path
      )
    )
  }

  private func makeProject(
    root: URL,
    commands: [VerificationCommand],
    policy: ProjectAccessPolicy = .init()
  ) throws -> RegisteredProject {
    let registeredRoot = try RegisteredRoot(capturing: root)
    return RegisteredProject(
      id: ProjectID(rawValue: "prj_verification_fixture"),
      name: "Verification Fixture",
      primaryRoot: registeredRoot,
      repositoryRoot: registeredRoot,
      accessPolicy: policy,
      verificationCommands: commands,
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }
}

private struct ScratchDirectory {
  let url: URL

  init(label: String) throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "bridge-verification-\(label)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
