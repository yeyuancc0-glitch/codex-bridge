import BridgeDirectCommand
import BridgeProcessRuntime
import BridgeWindowsSandboxSupport
import Foundation
import XCTest

final class WindowsJobProcessTests: XCTestCase {
  func testJobTerminationKillsDescendantAndIsIdempotent() throws {
    let fixture = try fixtureURL()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex bridge job & argv \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let childPIDFile = directory.appendingPathComponent("child pid.txt")
    let heartbeatFile = directory.appendingPathComponent("child heartbeat.txt")
    let process = try WindowsJobProcess(
      configuration: WindowsJobProcessConfiguration(
        executableURL: fixture,
        arguments: ["--parent", childPIDFile.path, heartbeatFile.path],
        currentDirectoryURL: directory
      )
    )
    defer {
      _ = process.terminateTree()
      _ = process.waitForExit(timeout: .seconds(5))
      process.close()
    }

    XCTAssertTrue(
      waitUntil(timeout: .seconds(5)) {
        FileManager.default.fileExists(atPath: childPIDFile.path)
          && FileManager.default.fileExists(atPath: heartbeatFile.path)
      })
    let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let childPID = try XCTUnwrap(UInt32(childPIDText))
    let childIdentity = try XCTUnwrap(
      WindowsJobProcess.currentIdentity(processID: childPID)
    )

    XCTAssertTrue(process.isRunning)
    XCTAssertTrue(process.terminateTree())
    XCTAssertTrue(process.terminateTree())
    XCTAssertNotNil(process.waitForExit(timeout: .seconds(5)))
    XCTAssertTrue(
      waitUntil(timeout: .seconds(5)) {
        WindowsJobProcess.currentIdentity(processID: childPID) != childIdentity
      })
  }

  func testNetworkDeniedDirectProcessUsesOfflineAppContainer() throws {
    let output = try sandboxTokenOutput(allowsNetwork: false)
    XCTAssertEqual(output, "appcontainer=1;internet=0")
  }

  func testNetworkEnabledDirectProcessUsesInternetClientAppContainer() throws {
    let output = try sandboxTokenOutput(allowsNetwork: true)
    XCTAssertEqual(output, "appcontainer=1;internet=1")
  }

  func testNetworkDeniedAppContainerCannotReachListeningLoopbackSocket() throws {
    var port = UInt16(0)
    let listener = bridge_create_loopback_listener(&port)
    XCTAssertNotEqual(listener, 0)
    XCTAssertNotEqual(port, 0)
    defer { bridge_close_socket(listener) }
    XCTAssertTrue(bridge_loopback_connect(port))

    let output = try sandboxTokenOutput(allowsNetwork: false, loopbackPort: port)
    XCTAssertEqual(output, "appcontainer=1;internet=0;connect=0")
  }

  func testAppContainerWritesOnlyInsideGrantedProjectRoot() throws {
    let fixture = try fixtureURL()
    let root = try makeTemporaryDirectory(label: "sandbox-project")
    let outside = try makeTemporaryDirectory(label: "sandbox-outside")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let isolatedFixture = root.appendingPathComponent("sandbox-fixture.exe")
    try FileManager.default.copyItem(at: fixture, to: isolatedFixture)
    let insideFile = root.appendingPathComponent("inside.txt")
    let outsideFile = outside.appendingPathComponent("outside.txt")
    let collector = DirectCommandOutputCollector()
    let process = try DirectProcessLifetime(
      argv: [isolatedFixture.path, "--sandbox-files", insideFile.path, outsideFile.path],
      workingDirectory: root.path,
      environment: nil,
      usePTY: false,
      output: collector,
      sandboxRoot: root.path,
      denyNetwork: true
    )
    defer { process.close() }
    XCTAssertEqual(process.waitForExit(timeout: .seconds(10)), .exited(0))
    process.drainRemainingOutput()
    XCTAssertEqual(
      collector.snapshot().tail.trimmingCharacters(in: .whitespacesAndNewlines),
      "inside=1;outside=0"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: insideFile.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))
  }

  private func sandboxTokenOutput(
    allowsNetwork: Bool,
    loopbackPort: UInt16? = nil
  ) throws -> String {
    let fixture = try fixtureURL()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex bridge appcontainer \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let isolatedFixture = directory.appendingPathComponent("sandbox-fixture.exe")
    try FileManager.default.copyItem(at: fixture, to: isolatedFixture)
    let collector = DirectCommandOutputCollector()
    let arguments =
      loopbackPort.map { ["--sandbox-network", String($0)] }
      ?? ["--sandbox-token"]
    let process = try DirectProcessLifetime(
      argv: [isolatedFixture.path] + arguments,
      workingDirectory: directory.path,
      environment: nil,
      usePTY: false,
      output: collector,
      sandboxRoot: directory.path,
      denyNetwork: !allowsNetwork
    )
    defer { process.close() }
    XCTAssertEqual(process.waitForExit(timeout: .seconds(10)), .exited(0))
    process.drainRemainingOutput()
    return collector.snapshot().tail.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func fixtureURL() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment["BRIDGE_WINDOWS_PROCESS_FIXTURE"] {
      let url = URL(fileURLWithPath: configured)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }

    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
      .standardizedFileURL
    let directory = testExecutable.deletingLastPathComponent()
    for name in [
      "windows-process-tree-fixture.exe",
      "WindowsProcessTreeFixture.exe",
    ] {
      let candidate = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    throw XCTSkip("Windows process-tree fixture was not built beside the test executable")
  }

  private func makeTemporaryDirectory(label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex bridge \(label) \(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func waitUntil(
    timeout: Duration,
    condition: () -> Bool
  ) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
  }
}
