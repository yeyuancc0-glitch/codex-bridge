import Foundation
import XCTest

@testable import BridgeGit

final class BoundedProcessRunnerTests: XCTestCase {
  func testRunnerEnforcesOutputLimitWithoutShell() async throws {
    let root = try makeScratchDirectory(label: "runner-output")
    defer { removeScratchDirectory(root) }
    let workingDirectory = try OpenedWorkingDirectory(canonicalURL: root)
    let result = try await BoundedProcessRunner().run(
      configuration(
        executable: "/usr/bin/yes",
        arguments: ["bounded"],
        workingDirectory: workingDirectory,
        timeout: .seconds(2),
        maximumOutputBytes: 64
      )
    )

    XCTAssertEqual(result.termination, .outputLimit)
    XCTAssertEqual(result.standardOutput.count, 64)
    XCTAssertTrue(result.standardOutputTruncated)
    XCTAssertLessThanOrEqual(result.standardError.count, 32)
  }

  func testRunnerTerminatesTimedOutProcess() async throws {
    let root = try makeScratchDirectory(label: "runner-timeout")
    defer { removeScratchDirectory(root) }
    let workingDirectory = try OpenedWorkingDirectory(canonicalURL: root)
    do {
      _ = try await BoundedProcessRunner().run(
        configuration(
          executable: "/bin/sleep",
          arguments: ["2"],
          workingDirectory: workingDirectory,
          timeout: .milliseconds(25),
          maximumOutputBytes: 64
        )
      )
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? BoundedProcessError, .timedOut)
    }
  }

  func testRunnerUsesOnlyExplicitEnvironment() async throws {
    let root = try makeScratchDirectory(label: "runner-environment")
    defer { removeScratchDirectory(root) }
    let workingDirectory = try OpenedWorkingDirectory(canonicalURL: root)
    let result = try await BoundedProcessRunner().run(
      BoundedProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [],
        workingDirectory: workingDirectory,
        environment: ["BRIDGE_GIT_TEST=present"],
        timeout: .seconds(1),
        terminationGracePeriod: .milliseconds(25),
        maximumStandardOutputBytes: 1_024,
        maximumStandardErrorBytes: 32
      )
    )

    XCTAssertEqual(result.termination, .exited(0))
    XCTAssertEqual(
      String(decoding: result.standardOutput, as: UTF8.self),
      "BRIDGE_GIT_TEST=present\n"
    )
  }

  func testRunnerBindsWorkingDirectoryDescriptorAcrossPathReplacement() async throws {
    let parent = try makeScratchDirectory(label: "runner-root-swap")
    defer { removeScratchDirectory(parent) }
    let root = parent.appending(path: "project", directoryHint: .isDirectory)
    let moved = parent.appending(path: "moved", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let workingDirectory = try OpenedWorkingDirectory(canonicalURL: root)
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    let result = try await BoundedProcessRunner().run(
      configuration(
        executable: "/usr/bin/touch",
        arguments: ["descriptor-marker"],
        workingDirectory: workingDirectory,
        timeout: .seconds(1),
        maximumOutputBytes: 64
      )
    )

    XCTAssertEqual(result.termination, .exited(0))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: moved.appending(path: "descriptor-marker").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appending(path: "descriptor-marker").path)
    )
    XCTAssertThrowsError(try workingDirectory.validatePathIdentity()) { error in
      XCTAssertEqual(error as? GitEvidenceError, .invalidAuthorizedRoot)
    }
  }

  private func configuration(
    executable: String,
    arguments: [String],
    workingDirectory: OpenedWorkingDirectory,
    timeout: Duration,
    maximumOutputBytes: Int
  ) -> BoundedProcessConfiguration {
    BoundedProcessConfiguration(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: ["PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C"],
      timeout: timeout,
      terminationGracePeriod: .milliseconds(25),
      maximumStandardOutputBytes: maximumOutputBytes,
      maximumStandardErrorBytes: 32
    )
  }
}
