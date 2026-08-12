import BridgeSecurity
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import BridgeTunnel

final class TunnelManagerTests: XCTestCase {
  func testDoctorUsesDescriptorsAndRedactsOutput() async throws {
    let harness = try Harness(tunnelSuffix: String(repeating: "a", count: 32))
    defer { harness.cleanup() }
    let manager = try harness.manager()
    let report = try await manager.doctor()
    XCTAssertFalse(report.output.contains(harness.key))
    XCTAssertFalse(report.output.contains(harness.localURL.absoluteString))
    XCTAssertTrue(report.output.contains("<redacted>"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
  }

  func testCancellingDoctorTerminatesAndReapsChild() async throws {
    let harness = try Harness(
      tunnelSuffix: "slowdoctor" + String(repeating: "e", count: 22)
    )
    defer { harness.cleanup() }
    let manager = try harness.manager()
    let doctor = Task { try await manager.doctor() }
    defer { doctor.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !harness.hasObservedProcess(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let observed = try harness.observed()
    let pid = try XCTUnwrap(observed["pid"] as? NSNumber).int32Value

    doctor.cancel()
    do {
      _ = try await doctor.value
      XCTFail("Expected doctor cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected cancellation error: \(error)")
    }

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testStartReadyRejectsDuplicateAndStopsWithoutLeaks() async throws {
    let harness = try Harness(tunnelSuffix: String(repeating: "b", count: 32))
    defer { harness.cleanup() }
    let manager = try harness.manager()
    try await manager.start()
    let readyState = await manager.state()
    XCTAssertEqual(readyState, .ready)
    let acceptsRemote = await manager.acceptsRemoteSubmissions()
    XCTAssertTrue(acceptsRemote)
    do {
      try await manager.start()
      XCTFail("Expected duplicate start rejection")
    } catch {
      XCTAssertEqual(error as? TunnelManagerError, .alreadyRunning)
    }
    let observed = try harness.observed()
    let arguments = try XCTUnwrap(observed["arguments"] as? [String])
    XCTAssertEqual(arguments.dropFirst().first, "run")
    XCTAssertFalse(arguments.contains(harness.key))
    XCTAssertFalse(arguments.contains(harness.localMCPHeaderSecret))
    XCTAssertEqual(observed["key"] as? String, harness.key)
    XCTAssertEqual(observed["mcp_secret"] as? String, harness.localMCPHeaderSecret)
    XCTAssertEqual(observed["configured_url"] as? String, "http://127.0.0.1:43210/mcp")
    XCTAssertEqual(observed["stdin_eof"] as? Bool, true)
    let environment = try XCTUnwrap(observed["environment"] as? [String: String])
    let run = try harness.runDirectory()
    XCTAssertEqual(
      environment["TMPDIR"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      run.resolvingSymlinksInPath().path
    )
    XCTAssertEqual(
      environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      run.appendingPathComponent("codex-home").resolvingSymlinksInPath().path
    )
    for forbidden in ["HOME", "PATH", "OPENAI_API_KEY", "MCP_SERVER_URL"] {
      XCTAssertNil(environment[forbidden])
    }
    XCTAssertFalse(arguments.contains("--config"))
    XCTAssertTrue(arguments.contains("--control-plane.api-key=file:/dev/fd/3"))
    XCTAssertTrue(arguments.contains("X-Codex-Bridge-Token: file:/dev/fd/4"))
    XCTAssertTrue(arguments.contains("http://127.0.0.1:43210/mcp"))
    XCTAssertFalse(arguments.contains(String(repeating: "A", count: 43)))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: run.appendingPathComponent("tunnel.yaml").path))
    let runMode = try FileManager.default.attributesOfItem(atPath: run.path)[.posixPermissions]
    XCTAssertEqual((runMode as? NSNumber)?.intValue, 0o700)
    let diagnostics = await manager.diagnostics()
    XCTAssertFalse(diagnostics.standardOutput.contains(harness.key))
    XCTAssertFalse(diagnostics.standardError.contains(harness.localURL.absoluteString))
    let stopClock = ContinuousClock()
    let stopStart = stopClock.now
    await manager.stop()
    XCTAssertLessThan(stopStart.duration(to: stopClock.now), .seconds(2))
    let stoppedState = await manager.state()
    XCTAssertEqual(stoppedState, .stopped)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
  }

  func testDoctorFailureAndUnexpectedRunExitBecomeFailures() async throws {
    let doctorHarness = try Harness(
      tunnelSuffix: "doctorfail" + String(repeating: "a", count: 22)
    )
    defer { doctorHarness.cleanup() }
    let doctorManager = try doctorHarness.manager()
    do {
      try await doctorManager.start()
      XCTFail("Expected doctor failure")
    } catch let error as TunnelManagerError {
      guard case .doctorFailed(let code, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(code, 2)
    }
    let doctorState = await doctorManager.state()
    XCTAssertEqual(doctorState, .failed)

    let exitHarness = try Harness(tunnelSuffix: "exit" + String(repeating: "c", count: 28))
    defer { exitHarness.cleanup() }
    let exitManager = try exitHarness.manager()
    do {
      try await exitManager.start()
      XCTFail("Expected helper exit")
    } catch {
      XCTAssertEqual(error as? TunnelManagerError, .helperExited(exitCode: 7))
    }
    let exitState = await exitManager.state()
    XCTAssertEqual(exitState, .failed)
  }

  func testMonitorRecordsUnexpectedExitAfterReady() async throws {
    let harness = try Harness(
      tunnelSuffix: "laterexit" + String(repeating: "d", count: 23),
      healthInterval: .milliseconds(50)
    )
    defer { harness.cleanup() }
    let manager = try harness.manager()
    try await manager.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await manager.state() != .failed, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let failedState = await manager.state()
    XCTAssertEqual(failedState, .failed)
  }

  func testStdoutAuthorizationFailureNeverAcceptsRemoteSubmissions() async throws {
    let harness = try Harness(
      tunnelSuffix: "authfail" + String(repeating: "f", count: 24),
      readinessTimeout: .milliseconds(500)
    )
    defer { harness.cleanup() }
    let manager = try harness.manager()
    do {
      try await manager.start()
      XCTFail("Expected authorization failure to prevent readiness")
    } catch {
      XCTAssertEqual(error as? TunnelManagerError, .readinessTimedOut)
    }
    let diagnostics = await manager.diagnostics()
    XCTAssertTrue(diagnostics.actionRequired)
    let acceptsRemote = await manager.acceptsRemoteSubmissions()
    XCTAssertFalse(acceptsRemote)
  }

  func testInvalidRuntimeRootPermissionsAreRejectedWithoutMutation() async throws {
    let harness = try Harness(tunnelSuffix: String(repeating: "g", count: 32))
    defer { harness.cleanup() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: harness.runtime.path
    )
    let manager = try harness.manager()
    do {
      _ = try await manager.doctor()
      XCTFail("Expected insecure root rejection")
    } catch {
      XCTAssertEqual(error as? TunnelManagerError, .launchFailed)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: harness.runtime.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
  }

  func testDynamicIdentityFailureNeverReleasesSuspendedHelper() async throws {
    let harness = try Harness(tunnelSuffix: String(repeating: "h", count: 32))
    defer { harness.cleanup() }
    let manager = try harness.manager(codeSignatureVerifier: RejectingDynamicVerifier())
    do {
      _ = try await manager.doctor()
      XCTFail("Expected dynamic identity rejection")
    } catch {
      XCTAssertEqual(error as? TunnelHelperError, .identityMismatch)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
  }

  func testConcreteMacOSVerifierBindsAndResumesSuspendedFixture() async throws {
    let harness = try Harness(tunnelSuffix: String(repeating: "i", count: 32))
    defer { harness.cleanup() }
    let verifier = MacOSTunnelCodeSignatureVerifier(requiresHostTeam: false)
    let manager = try harness.manager(codeSignatureVerifier: verifier)
    let report = try await manager.doctor()
    XCTAssertTrue(report.output.contains("<redacted>"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
  }

  func testStopEscalatesTermIgnoringHelperAndReapsExactPID() async throws {
    let harness = try Harness(
      tunnelSuffix: "ignoreterm" + String(repeating: "j", count: 22),
      processTimeout: .milliseconds(200)
    )
    defer { harness.cleanup() }
    let manager = try harness.manager()
    try await manager.start()
    let observed = try harness.observed()
    let pid = try XCTUnwrap(observed["pid"] as? NSNumber).int32Value

    await manager.stop()

    let state = await manager.state()
    XCTAssertEqual(state, .stopped)
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testStopDuringStartOwnsTerminationAndLeavesNoRuntime() async throws {
    let harness = try Harness(
      tunnelSuffix: "slowdoctor" + String(repeating: "k", count: 22)
    )
    defer { harness.cleanup() }
    let manager = try harness.manager()
    let start = Task { try await manager.start() }
    defer { start.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !harness.hasObservedProcess(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    await manager.stop()
    do {
      try await start.value
      XCTFail("Expected stopped start")
    } catch {
      XCTAssertEqual(error as? TunnelManagerError, .stopped)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.runtime.path), [])
  }
}

private final class TestSecretStore: SecretStore, @unchecked Sendable {
  private let data: Data

  init(data: Data) { self.data = data }

  func store(_: Data, for _: SecretReference) throws {}
  func load(_: SecretReference) throws -> Data { data }
  func remove(_: SecretReference) throws {}
}

private struct Harness {
  let root: URL
  let runtime: URL
  let key = "runtime_key_fixture_123"
  let localURL = URL(string: "http://127.0.0.1:43210/mcp")!
  let localMCPHeaderSecret = String(repeating: "A", count: 43)
  let tunnelSuffix: String
  let healthInterval: Duration
  let readinessTimeout: Duration
  let processTimeout: Duration

  init(
    tunnelSuffix: String,
    healthInterval: Duration = .milliseconds(100),
    readinessTimeout: Duration = .seconds(3),
    processTimeout: Duration = .seconds(3)
  ) throws {
    self.tunnelSuffix = tunnelSuffix
    self.healthInterval = healthInterval
    self.readinessTimeout = readinessTimeout
    self.processTimeout = processTimeout
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bt-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    runtime = root.appendingPathComponent("r", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: runtime.path
    )
  }

  func manager(
    codeSignatureVerifier: any TunnelCodeSignatureVerifier = TestCodeSignatureVerifier()
  ) throws -> TunnelManager {
    let helper = try Self.helperURL()
    let digest = try Self.digest(helper)
    let reference = try SecretReference(validating: "runtime-key.fixture")
    let configuration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: try TunnelID(validating: "tunnel_\(tunnelSuffix)"),
      runtimeKeyReference: reference,
      localMCPURL: localURL,
      localMCPHeaderSecret: localMCPHeaderSecret,
      runtimeDirectory: runtime,
      readinessTimeout: readinessTimeout,
      healthInterval: healthInterval,
      processTimeout: processTimeout,
      expectedHelperSHA256: digest
    )
    return TunnelManager(
      configuration: configuration,
      secretStore: TestSecretStore(data: Data(key.utf8)),
      helperVerifier: TunnelHelperVerifier(codeSignatureVerifier: codeSignatureVerifier)
    )
  }

  func observed() throws -> [String: Any] {
    let run = try runDirectory()
    let data = try Data(contentsOf: run.appendingPathComponent("observed.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func hasObservedProcess() -> Bool {
    guard let run = currentRunDirectory() else { return false }
    return FileManager.default.fileExists(
      atPath: run.appendingPathComponent("observed.json").path
    )
  }

  func runDirectory() throws -> URL {
    try XCTUnwrap(currentRunDirectory())
  }

  private func currentRunDirectory() -> URL? {
    try? FileManager.default.contentsOfDirectory(
      at: runtime,
      includingPropertiesForKeys: nil
    ).first
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }

  private static func helperURL() throws -> URL {
    let testBundle = Bundle(for: TunnelManagerTests.self).bundleURL
    let directory = testBundle.deletingLastPathComponent()
    let candidates = [
      directory.appendingPathComponent("bridge-tunnel-fixture"),
      directory.deletingLastPathComponent().appendingPathComponent("bridge-tunnel-fixture"),
    ]
    return try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  private static func digest(_ file: URL) throws -> String {
    let data = try Data(contentsOf: file)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct TestCodeSignatureVerifier: TunnelCodeSignatureVerifier {
  func verifyStatic(executableDescriptor _: Int32) throws -> TunnelCodeIdentity {
    TunnelCodeIdentity(codeDirectoryHash: Data("fixture-identity".utf8))
  }

  func verifyDynamic(processID _: Int32, expectedIdentity _: TunnelCodeIdentity) throws {}
}

private struct RejectingDynamicVerifier: TunnelCodeSignatureVerifier {
  func verifyStatic(executableDescriptor _: Int32) throws -> TunnelCodeIdentity {
    TunnelCodeIdentity(codeDirectoryHash: Data("fixture-identity".utf8))
  }

  func verifyDynamic(processID _: Int32, expectedIdentity _: TunnelCodeIdentity) throws {
    throw TunnelHelperError.identityMismatch
  }
}
