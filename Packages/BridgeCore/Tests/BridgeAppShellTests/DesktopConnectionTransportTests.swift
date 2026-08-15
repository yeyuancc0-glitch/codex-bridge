import BridgeSecurity
import BridgeTunnel
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopConnectionTransportTests: XCTestCase {
  func testLocalTransportIsReadyButNeverClaimsRemoteReachability() async throws {
    let mcp = ConnectionTestMCP()
    let runtime = DesktopConnectionRuntime(
      mcp: mcp,
      tunnelFactory: ConnectionTestTunnelFactory()
    )

    let url = try await runtime.configure(
      .local(pathSecret: String(repeating: "a", count: 43))
    )
    try await runtime.testConnection()
    let health = await runtime.health()
    let testCount = await mcp.testCount()

    XCTAssertEqual(url.host, "127.0.0.1")
    XCTAssertEqual(health.lifecycle, .ready)
    XCTAssertFalse(health.acceptsRemoteSubmissions)
    XCTAssertEqual(testCount, 1)
    await runtime.stop()
    let stopCount = await mcp.stopCount()
    XCTAssertEqual(stopCount, 1)
  }

  func testManualTransportRequiresHTTPSStrongAuthorizationAndRemoteContract() async throws {
    let mcp = ConnectionTestMCP()
    let remote = ConnectionTestRemoteMCP()
    let runtime = DesktopConnectionRuntime(
      mcp: mcp,
      remoteTester: remote,
      tunnelFactory: ConnectionTestTunnelFactory()
    )

    do {
      _ = try await runtime.configureManual(
        localAuthentication: .path(secret: String(repeating: "b", count: 43)),
        endpoint: URL(string: "http://bridge.example/mcp")!,
        authorization: "Bearer strong-test-token"
      )
      XCTFail("Expected HTTP endpoint rejection")
    } catch {
      XCTAssertEqual(error as? DesktopTransportError, .invalidManualEndpoint)
    }

    let endpoint = URL(string: "https://bridge.example/mcp")!
    _ = try await runtime.configureManual(
      localAuthentication: .path(secret: String(repeating: "c", count: 43)),
      endpoint: endpoint,
      authorization: "Bearer strong-test-token"
    )
    try await runtime.testConnection()
    let health = await runtime.health()
    let request = await remote.lastRequest()

    XCTAssertEqual(request?.0, endpoint)
    XCTAssertEqual(request?.1, "Bearer strong-test-token")
    XCTAssertEqual(health.lifecycle, .ready)
    XCTAssertTrue(health.acceptsRemoteSubmissions)
    await runtime.stop()
  }

  func testSecureTransportRequiresTunnelReadinessAndStopsBothProcesses() async throws {
    let mcp = ConnectionTestMCP()
    let tunnel = ConnectionTestTunnel()
    let factory = ConnectionTestTunnelFactory(tunnel: tunnel)
    let runtime = DesktopConnectionRuntime(mcp: mcp, tunnelFactory: factory)
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    let reference = try SecretReference(validating: "runtime-key.test")
    let secret = String(repeating: "d", count: 43)

    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: reference,
      localMCPHeaderSecret: secret
    )
    try await runtime.testConnection()
    let health = await runtime.health()
    let captured = await factory.capturedConfiguration()
    let tunnelStartCount = await tunnel.startCount()

    XCTAssertEqual(captured?.0, tunnelID)
    XCTAssertEqual(captured?.1, reference)
    XCTAssertEqual(captured?.2, secret)
    XCTAssertTrue(health.acceptsRemoteSubmissions)
    XCTAssertEqual(tunnelStartCount, 1)
    await runtime.stop()
    let tunnelStopCount = await tunnel.stopCount()
    let mcpStopCount = await mcp.stopCount()
    XCTAssertEqual(tunnelStopCount, 1)
    XCTAssertEqual(mcpStopCount, 1)
  }

  func testReplacingModeStopsPreviousTransportBeforeStartingNext() async throws {
    let mcp = ConnectionTestMCP()
    let runtime = DesktopConnectionRuntime(
      mcp: mcp,
      remoteTester: ConnectionTestRemoteMCP(),
      tunnelFactory: ConnectionTestTunnelFactory()
    )

    _ = try await runtime.configureLocal(
      authentication: .path(secret: String(repeating: "e", count: 43))
    )
    _ = try await runtime.configureManual(
      localAuthentication: .path(secret: String(repeating: "f", count: 43)),
      endpoint: URL(string: "https://bridge.example/mcp")!,
      authorization: "Bearer another-test-token"
    )

    let startCount = await mcp.startCount()
    let stopCount = await mcp.stopCount()
    XCTAssertEqual(startCount, 2)
    XCTAssertEqual(stopCount, 1)
    await runtime.stop()
  }

  func testBundledFactoryFailsClosedWithoutSignedHelper() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-transport-factory-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = BundledDesktopTunnelManagerFactory(
      bundleURL: directory,
      dataDirectoryURL: directory,
      secretStore: ConnectionTestSecretStore()
    )

    do {
      _ = try await factory.make(
        tunnelID: TunnelID(rawValue: "tunnel_\(String(repeating: "z", count: 32))"),
        runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
        localMCPURL: URL(string: "http://127.0.0.1:43210/mcp")!,
        localMCPHeaderSecret: String(repeating: "g", count: 43)
      )
      XCTFail("Expected missing helper rejection")
    } catch {
      XCTAssertEqual(error as? DesktopTransportError, .helperUnavailable)
    }
  }

  func testConnectionStateRequiresRemoteReadiness() {
    let local = DesktopTransportHealth(
      lifecycle: .ready,
      acceptsRemoteSubmissions: false,
      endpointDescription: "仅本机开发",
      localMCPURL: URL(string: "http://127.0.0.1:43210/mcp/local"),
      actionRequired: false
    )
    let remote = DesktopTransportHealth(
      lifecycle: .ready,
      acceptsRemoteSubmissions: true,
      endpointDescription: "OpenAI Secure MCP Tunnel",
      localMCPURL: URL(string: "http://127.0.0.1:43210/mcp"),
      actionRequired: false
    )

    XCTAssertEqual(LiveBridgeAppBackend.connectionState(local), .degraded)
    XCTAssertEqual(LiveBridgeAppBackend.connectionState(remote), .ready)
  }

  func testSecureTunnelHealthChangesArePublishedWithoutManualRefresh() async throws {
    let tunnel = ConnectionTestTunnel()
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(tunnel: tunnel),
      monitorInterval: .milliseconds(10)
    )
    let updates = await runtime.stateUpdates()
    let degraded = expectation(description: "degraded health published")
    let observer = Task {
      for await health in updates where health.lifecycle == .degraded {
        degraded.fulfill()
        return
      }
    }
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
      localMCPHeaderSecret: String(repeating: "h", count: 43)
    )
    await tunnel.setLifecycle(.degraded)

    await fulfillment(of: [degraded], timeout: 1)
    observer.cancel()
    await runtime.stop()
  }

  func testSecureTransportRestartsFailedHelperWithoutRestartingLocalMCP() async throws {
    let mcp = ConnectionTestMCP()
    let first = ConnectionTestTunnel()
    let replacement = ConnectionTestTunnel()
    let factory = ConnectionSequenceTunnelFactory(tunnels: [first, replacement])
    let transport = SecureMCPTunnelTransport(
      mcp: mcp,
      tunnelFactory: factory,
      tunnelID: try TunnelID(validating: "tunnel_\(String(repeating: "r", count: 32))"),
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.restart"),
      localMCPHeaderSecret: String(repeating: "s", count: 43),
      restartDelays: [.milliseconds(1)]
    )
    try await transport.start()
    await first.setLifecycle(.failed)

    let degraded = await transport.health()
    XCTAssertEqual(degraded.lifecycle, .degraded)
    XCTAssertFalse(degraded.acceptsRemoteSubmissions)
    try await waitUntil { await replacement.startCount() == 1 }

    let recovered = await transport.health()
    let localStarts = await mcp.startCount()
    let localStops = await mcp.stopCount()
    let firstStops = await first.stopCount()
    let factoryMakes = await factory.makeCount()
    XCTAssertEqual(recovered.lifecycle, .ready)
    XCTAssertTrue(recovered.acceptsRemoteSubmissions)
    XCTAssertEqual(localStarts, 1)
    XCTAssertEqual(localStops, 0)
    XCTAssertEqual(firstStops, 1)
    XCTAssertEqual(factoryMakes, 2)
    await transport.stop()
  }

  func testSecureTransportDoesNotRetryAuthenticationFailure() async throws {
    let tunnel = ConnectionTestTunnel()
    let factory = ConnectionSequenceTunnelFactory(tunnels: [tunnel])
    let transport = SecureMCPTunnelTransport(
      mcp: ConnectionTestMCP(),
      tunnelFactory: factory,
      tunnelID: try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))"),
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.auth-failure"),
      localMCPHeaderSecret: String(repeating: "t", count: 43),
      restartDelays: [.milliseconds(1)]
    )
    try await transport.start()
    await tunnel.setLifecycle(.failed)
    await tunnel.setActionRequired(true)

    let health = await transport.health()
    try await Task.sleep(for: .milliseconds(20))
    let factoryMakes = await factory.makeCount()
    XCTAssertEqual(health.lifecycle, .failed)
    XCTAssertTrue(health.actionRequired)
    XCTAssertEqual(factoryMakes, 1)
    await transport.stop()
  }

  func testSecureTransportBoundsRestartAttemptsAndRequiresManualRecovery() async throws {
    let initial = ConnectionTestTunnel()
    let failures = (0..<3).map { _ in ConnectionTestTunnel(failsOnStart: true) }
    let factory = ConnectionSequenceTunnelFactory(tunnels: [initial] + failures)
    let transport = SecureMCPTunnelTransport(
      mcp: ConnectionTestMCP(),
      tunnelFactory: factory,
      tunnelID: try TunnelID(validating: "tunnel_\(String(repeating: "b", count: 32))"),
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.exhausted"),
      localMCPHeaderSecret: String(repeating: "u", count: 43),
      restartDelays: [.zero, .zero, .zero]
    )
    try await transport.start()
    await initial.setLifecycle(.failed)
    _ = await transport.health()
    try await waitUntil { await factory.makeCount() == 4 }
    try await waitUntil { await transport.health().actionRequired }

    let exhausted = await transport.health()
    XCTAssertEqual(exhausted.lifecycle, .failed)
    XCTAssertFalse(exhausted.acceptsRemoteSubmissions)
    XCTAssertTrue(exhausted.actionRequired)
    await transport.stop()
  }

  func testSecureTransportStopCancelsPendingRestart() async throws {
    let initial = ConnectionTestTunnel()
    let replacement = ConnectionTestTunnel()
    let factory = ConnectionSequenceTunnelFactory(tunnels: [initial, replacement])
    let mcp = ConnectionTestMCP()
    let transport = SecureMCPTunnelTransport(
      mcp: mcp,
      tunnelFactory: factory,
      tunnelID: try TunnelID(validating: "tunnel_\(String(repeating: "c", count: 32))"),
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.cancel"),
      localMCPHeaderSecret: String(repeating: "v", count: 43),
      restartDelays: [.milliseconds(100)]
    )
    try await transport.start()
    await initial.setLifecycle(.failed)
    _ = await transport.health()

    await transport.stop()
    try await Task.sleep(for: .milliseconds(150))
    let factoryMakes = await factory.makeCount()
    let localStops = await mcp.stopCount()
    let replacementStarts = await replacement.startCount()
    XCTAssertEqual(factoryMakes, 1)
    XCTAssertEqual(localStops, 1)
    XCTAssertEqual(replacementStarts, 0)
  }

  func testRemoteSubmissionCheckReadsTunnelHealthWithoutWaitingForMonitor() async throws {
    let tunnel = ConnectionTestTunnel()
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(tunnel: tunnel),
      monitorInterval: .seconds(60)
    )
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
      localMCPHeaderSecret: String(repeating: "i", count: 43)
    )

    let acceptsWhileReady = await runtime.acceptsRemoteSubmissionsNow()
    XCTAssertTrue(acceptsWhileReady)
    await tunnel.setLifecycle(.degraded)
    let acceptsWhileDegraded = await runtime.acceptsRemoteSubmissionsNow()
    XCTAssertFalse(acceptsWhileDegraded)
    await runtime.stop()
  }

  func testSleepDrainWaitsForAnAdmittedRemoteSubmissionLease() async throws {
    let tunnel = ConnectionTestTunnel()
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(tunnel: tunnel),
      monitorInterval: .seconds(60)
    )
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
      localMCPHeaderSecret: String(repeating: "m", count: 43)
    )
    let acquiredLease = await runtime.acquireRemoteSubmissionLease()
    let lease = try XCTUnwrap(acquiredLease)
    let probe = ConnectionDrainProbe()
    await runtime.suspendRemoteAdmissionsForSleep()
    let drain = Task {
      await runtime.waitForRemoteSubmissionDrain()
      await probe.markDrained()
    }
    try await Task.sleep(for: .milliseconds(20))
    let drainedBeforeRelease = await probe.isDrained
    XCTAssertFalse(drainedBeforeRelease)

    lease.release()
    await drain.value
    let drainedAfterRelease = await probe.isDrained
    XCTAssertTrue(drainedAfterRelease)
    await runtime.stop()
  }

  func testSleepImmediatelyClosesRemoteAdmissionUntilWakeRevalidation() async throws {
    let tunnel = ConnectionTestTunnel()
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(tunnel: tunnel),
      monitorInterval: .seconds(60)
    )
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
      localMCPHeaderSecret: String(repeating: "j", count: 43)
    )

    let acceptedBeforeSleep = await runtime.acceptsRemoteSubmissionsNow()
    XCTAssertTrue(acceptedBeforeSleep)
    let testCountBeforeWake = await tunnel.admissionTestCount()
    await runtime.suspendRemoteAdmissionsForSleep()
    let acceptedWhileAsleep = await runtime.acceptsRemoteSubmissionsNow()
    let sleepingHealth = await runtime.health()
    XCTAssertFalse(acceptedWhileAsleep)
    XCTAssertFalse(sleepingHealth.acceptsRemoteSubmissions)

    try await runtime.revalidateRemoteAdmissionsAfterWake()
    let acceptedAfterWake = await runtime.acceptsRemoteSubmissionsNow()
    let testCountAfterWake = await tunnel.admissionTestCount()
    XCTAssertTrue(acceptedAfterWake)
    XCTAssertGreaterThanOrEqual(testCountAfterWake - testCountBeforeWake, 2)
    await runtime.stop()
  }

  func testFailedWakeRevalidationLeavesRemoteAdmissionClosed() async throws {
    let tunnel = ConnectionTestTunnel()
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(tunnel: tunnel),
      monitorInterval: .seconds(60)
    )
    let tunnelID = try TunnelID(validating: "tunnel_\(String(repeating: "a", count: 32))")
    _ = try await runtime.configureSecureTunnel(
      tunnelID: tunnelID,
      runtimeKeyReference: SecretReference(rawValue: "runtime-key.test"),
      localMCPHeaderSecret: String(repeating: "k", count: 43)
    )
    await runtime.suspendRemoteAdmissionsForSleep()
    await tunnel.setLifecycle(.degraded)

    do {
      try await runtime.revalidateRemoteAdmissionsAfterWake()
      XCTFail("Expected wake revalidation to fail")
    } catch {
      XCTAssertEqual(error as? DesktopTransportError, .connectionFailed)
    }
    let acceptedAfterFailure = await runtime.acceptsRemoteSubmissionsNow()
    let failedHealth = await runtime.health()
    XCTAssertFalse(acceptedAfterFailure)
    XCTAssertFalse(failedHealth.acceptsRemoteSubmissions)
    await runtime.stop()
  }

  func testLocalModeWakeRevalidationSucceedsWithoutClaimingRemoteAdmission() async throws {
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(),
      monitorInterval: .seconds(60)
    )
    _ = try await runtime.configureLocal(
      authentication: .path(secret: String(repeating: "l", count: 43))
    )
    await runtime.suspendRemoteAdmissionsForSleep()

    try await runtime.revalidateRemoteAdmissionsAfterWake()

    let health = await runtime.health()
    let accepts = await runtime.acceptsRemoteSubmissionsNow()
    XCTAssertEqual(health.lifecycle, .ready)
    XCTAssertFalse(health.acceptsRemoteSubmissions)
    XCTAssertFalse(accepts)
    await runtime.stop()
  }

  func testOrphanAndRepeatedWakeRevalidationAreIdempotent() async throws {
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(),
      monitorInterval: .seconds(60)
    )
    _ = try await runtime.configureLocal(
      authentication: .path(secret: String(repeating: "w", count: 43))
    )

    try await runtime.revalidateRemoteAdmissionsAfterWake()
    try await runtime.revalidateRemoteAdmissionsAfterWake()

    let health = await runtime.health()
    XCTAssertEqual(health.lifecycle, .ready)
    await runtime.stop()
  }

  func testSleepSupersedesAnOlderReplacementTransition() throws {
    let gate = DesktopRemoteAdmissionGate()
    let transition = try XCTUnwrap(gate.beginReplacement())

    gate.closeForSleep()

    XCTAssertTrue(gate.complete(transition))
    XCTAssertFalse(gate.snapshot().permitsRemoteSubmissions)
  }

  func testPermanentShutdownSupersedesAnOlderWakeTransition() throws {
    let gate = DesktopRemoteAdmissionGate()
    gate.closeForSleep()
    let transition = try XCTUnwrap(gate.beginWakeRevalidation())

    gate.closePermanently()

    XCTAssertFalse(gate.complete(transition))
    XCTAssertFalse(gate.snapshot().permitsRemoteSubmissions)
  }

  func testShutdownPermanentlyRejectsLaterConfiguration() async throws {
    let runtime = DesktopConnectionRuntime(
      mcp: ConnectionTestMCP(),
      tunnelFactory: ConnectionTestTunnelFactory(),
      monitorInterval: .seconds(60)
    )

    await runtime.shutdown()

    do {
      _ = try await runtime.configureLocal(
        authentication: .path(secret: String(repeating: "z", count: 43))
      )
      XCTFail("Expected a stopped runtime to reject replacement")
    } catch {
      XCTAssertEqual(error as? DesktopTransportError, .connectionFailed)
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for condition")
  }

}

private actor ConnectionDrainProbe {
  private(set) var isDrained = false

  func markDrained() {
    isDrained = true
  }
}

private actor ConnectionTestMCP: DesktopMCPServing {
  private var starts = 0
  private var stops = 0
  private var tests = 0

  func start(authentication: DesktopMCPAuthentication) -> URL {
    starts += 1
    switch authentication {
    case .path(let secret):
      return URL(string: "http://127.0.0.1:43210/mcp/\(secret)")!
    case .header:
      return URL(string: "http://127.0.0.1:43210/mcp")!
    }
  }

  func testConnection() {
    tests += 1
  }

  func stop() {
    stops += 1
  }

  func startCount() -> Int { starts }
  func stopCount() -> Int { stops }
  func testCount() -> Int { tests }
}

private actor ConnectionTestRemoteMCP: DesktopRemoteMCPTesting {
  private var request: (URL, String)?

  func validate(endpoint: URL, authorization: String) {
    request = (endpoint, authorization)
  }

  func lastRequest() -> (URL, String)? { request }
}

private actor ConnectionTestTunnel: DesktopTunnelManaging {
  private let failsOnStart: Bool
  private var starts = 0
  private var stops = 0
  private var admissionTests = 0
  private var lifecycle = TunnelLifecycle.stopped
  private var requiresAction = false

  init(failsOnStart: Bool = false) {
    self.failsOnStart = failsOnStart
  }

  func start() throws {
    starts += 1
    if failsOnStart {
      lifecycle = .failed
      throw DesktopTransportError.connectionFailed
    }
    lifecycle = .ready
  }
  func stop() {
    stops += 1
    lifecycle = .stopped
  }
  func state() -> TunnelLifecycle { lifecycle }
  func acceptsRemoteSubmissions() -> Bool {
    admissionTests += 1
    return lifecycle == .ready
  }
  func diagnostics() -> TunnelDiagnostics {
    TunnelDiagnostics(
      standardOutput: "",
      standardError: "",
      wasTruncated: false,
      actionRequired: requiresAction
    )
  }
  func startCount() -> Int { starts }
  func stopCount() -> Int { stops }
  func setLifecycle(_ value: TunnelLifecycle) { lifecycle = value }
  func setActionRequired(_ value: Bool) { requiresAction = value }
  func admissionTestCount() -> Int { admissionTests }
}

private actor ConnectionSequenceTunnelFactory: DesktopTunnelManagerBuilding {
  private let tunnels: [ConnectionTestTunnel]
  private var nextIndex = 0

  init(tunnels: [ConnectionTestTunnel]) {
    self.tunnels = tunnels
  }

  func make(
    tunnelID _: TunnelID,
    runtimeKeyReference _: SecretReference,
    localMCPURL _: URL,
    localMCPHeaderSecret _: String
  ) async throws -> any DesktopTunnelManaging {
    guard !tunnels.isEmpty else { throw DesktopTransportError.helperUnavailable }
    let index = min(nextIndex, tunnels.count - 1)
    nextIndex += 1
    return tunnels[index]
  }

  func makeCount() -> Int { nextIndex }
}

private actor ConnectionTestTunnelFactory: DesktopTunnelManagerBuilding {
  private let tunnel: ConnectionTestTunnel
  private var captured: (TunnelID, SecretReference, String)?

  init(tunnel: ConnectionTestTunnel = ConnectionTestTunnel()) {
    self.tunnel = tunnel
  }

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL _: URL,
    localMCPHeaderSecret: String
  ) async -> any DesktopTunnelManaging {
    captured = (tunnelID, runtimeKeyReference, localMCPHeaderSecret)
    return tunnel
  }

  func capturedConfiguration() -> (TunnelID, SecretReference, String)? { captured }
}

private struct ConnectionTestSecretStore: SecretStore {
  func store(_: Data, for _: SecretReference) throws {}
  func load(_: SecretReference) throws -> Data { throw SecretStoreError.notFound }
  func remove(_: SecretReference) throws {}
}
