import BridgeCodexRPC
import BridgeIPC
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeServiceHost
import BridgeTunnel
import Foundation
import XCTest

final class ServiceTunnelControllerTests: XCTestCase {
  func testConfigureDisconnectAndClearPersistOnlyNonSecretSettings() async throws {
    let fixture = try await makeTunnelFixture(self)
    let manager = TestServiceTunnelManager()
    let factory = TestServiceTunnelFactory(managers: [manager])
    let controller = ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: factory,
      monitorInterval: .milliseconds(20),
      restartDelays: []
    )
    await controller.bootstrap(
      localMCPURL: localMCPURL(port: 43_210),
      localMCPHeaderSecret: localMCPSecret
    )

    let configured = try await controller.configure(
      tunnelID: validTunnelID(suffix: "a"),
      runtimeKey: "runtime_key_fixture_123"
    )

    XCTAssertTrue(configured.configured)
    XCTAssertTrue(configured.enabled)
    XCTAssertEqual(configured.lifecycle, .ready)
    XCTAssertTrue(configured.acceptsRemoteSubmissions)
    let startCount = await manager.startCount()
    let storedTunnelID = try await fixture.settings.string(for: .tunnelID)
    let storedEnabled = try await fixture.settings.string(for: .tunnelEnabled)
    XCTAssertEqual(startCount, 1)
    XCTAssertEqual(storedTunnelID, validTunnelID(suffix: "a"))
    XCTAssertEqual(storedEnabled, "1")
    XCTAssertEqual(
      String(
        data: try fixture.secrets.load(ServiceTunnelController.runtimeKeyReference),
        encoding: .utf8
      ),
      "runtime_key_fixture_123"
    )

    try await controller.disconnect()
    let disconnected = await controller.status()
    XCTAssertTrue(disconnected.configured)
    XCTAssertFalse(disconnected.enabled)
    XCTAssertEqual(disconnected.lifecycle, .stopped)
    let stopCount = await manager.stopCount()
    let disconnectedEnabled = try await fixture.settings.string(for: .tunnelEnabled)
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(disconnectedEnabled, "0")
    XCTAssertNoThrow(
      try fixture.secrets.load(ServiceTunnelController.runtimeKeyReference)
    )

    try await controller.clearConfiguration()
    let cleared = await controller.status()
    XCTAssertFalse(cleared.configured)
    XCTAssertNil(cleared.tunnelID)
    let clearedTunnelID = try await fixture.settings.string(for: .tunnelID)
    let clearedEnabled = try await fixture.settings.string(for: .tunnelEnabled)
    XCTAssertNil(clearedTunnelID)
    XCTAssertNil(clearedEnabled)
    XCTAssertThrowsError(
      try fixture.secrets.load(ServiceTunnelController.runtimeKeyReference)
    ) { error in
      XCTAssertEqual(error as? SecretStoreError, .notFound)
    }
  }

  func testRuntimeKeyPreservesPrintableValueAndRejectsWhitespaceMutation() async throws {
    let fixture = try await makeTunnelFixture(self)
    let manager = TestServiceTunnelManager()
    let controller = ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: TestServiceTunnelFactory(managers: [manager]),
      restartDelays: []
    )
    await controller.bootstrap(
      localMCPURL: localMCPURL(port: 43_209),
      localMCPHeaderSecret: localMCPSecret
    )

    let runtimeKey = "sk-proj.fixture:key/value"
    _ = try await controller.configure(
      tunnelID: validTunnelID(suffix: "f"),
      runtimeKey: runtimeKey
    )
    XCTAssertEqual(
      String(
        data: try fixture.secrets.load(ServiceTunnelController.runtimeKeyReference),
        encoding: .utf8
      ),
      runtimeKey
    )

    for invalid in [" runtime_key", "runtime_key ", "runtime\nkey"] {
      do {
        _ = try await controller.configure(
          tunnelID: validTunnelID(suffix: "f"),
          runtimeKey: invalid
        )
        XCTFail("Expected whitespace-bearing Runtime Key to be rejected")
      } catch {
        XCTAssertEqual(error as? ServiceTunnelError, .invalidRuntimeKey)
      }
    }
  }

  func testMissingBundledHelperDoesNotBlockLocalServiceConfiguration() async throws {
    let fixture = try await makeTunnelFixture(self)
    let factory = TestServiceTunnelFactory(helperAvailable: false, managers: [])
    let controller = ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: factory,
      restartDelays: []
    )
    await controller.bootstrap(
      localMCPURL: localMCPURL(port: 43_211),
      localMCPHeaderSecret: localMCPSecret
    )

    do {
      _ = try await controller.configure(
        tunnelID: validTunnelID(suffix: "b"),
        runtimeKey: "runtime_key_fixture_456"
      )
      XCTFail("Expected a build without tunnel-client to reject remote startup")
    } catch {
      XCTAssertEqual(error as? ServiceTunnelError, .helperUnavailable)
    }

    let status = await controller.status()
    XCTAssertTrue(status.configured)
    XCTAssertTrue(status.enabled)
    XCTAssertFalse(status.helperAvailable)
    XCTAssertEqual(status.lifecycle, .failed)
    XCTAssertTrue(status.actionRequired)
    let runtime = await fixture.runtimeStatus.current()
    XCTAssertEqual(runtime.mcpState, "stopped")
    XCTAssertEqual(runtime.tunnelState, "failed")
  }

  func testBundledFactoryReadsDigestFromResourcesInsteadOfHelpers() async throws {
    let fixture = try await makeTunnelFixture(self)
    let bundle = FileManager.default.temporaryDirectory.appending(
      path: "service-tunnel-bundle-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: bundle) }
    let helpers = bundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
    let resources = bundle.appending(
      path: "Contents/Resources/TunnelClient",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let helper = helpers.appending(path: "tunnel-client")
    try Data("fixture".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let digest = resources.appending(path: "tunnel-client.sha256")
    try Data((String(repeating: "a", count: 64) + "\n").utf8).write(to: digest)

    let factory = BundledServiceTunnelManagerFactory(
      appBundleURL: bundle,
      runtimeDirectory: fixture.root.appending(path: "TunnelRuntime"),
      secretStore: fixture.secrets
    )
    XCTAssertTrue(factory.helperAvailable())

    try FileManager.default.moveItem(
      at: digest,
      to: helpers.appending(path: "tunnel-client.sha256")
    )
    XCTAssertFalse(factory.helperAvailable())
  }

  func testMCPAddressChangeStopsOldTunnelAndStartsReplacement() async throws {
    let fixture = try await makeTunnelFixture(self)
    let first = TestServiceTunnelManager()
    let second = TestServiceTunnelManager()
    let factory = TestServiceTunnelFactory(managers: [first, second])
    let controller = ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: factory,
      monitorInterval: .milliseconds(20),
      restartDelays: []
    )
    await controller.bootstrap(
      localMCPURL: localMCPURL(port: 43_212),
      localMCPHeaderSecret: localMCPSecret
    )
    _ = try await controller.configure(
      tunnelID: validTunnelID(suffix: "c"),
      runtimeKey: "runtime_key_fixture_789"
    )

    await controller.pauseForMCPRestart()
    await controller.localMCPDidChange(
      localMCPURL(port: 43_213),
      localMCPHeaderSecret: localMCPSecret
    )
    try await waitUntil {
      let startCount = await second.startCount()
      return factory.makeCount() == 2 && startCount == 1
    }

    let firstStopCount = await first.stopCount()
    let secondStartCount = await second.startCount()
    let ports = factory.localMCPPorts()
    let tunnelStatus = await controller.status()
    XCTAssertEqual(firstStopCount, 1)
    XCTAssertEqual(secondStartCount, 1)
    XCTAssertEqual(ports, [43_212, 43_213])
    XCTAssertEqual(tunnelStatus.lifecycle, .ready)
  }

  func testXPCConfiguresAndClearsTunnelWithoutReturningRuntimeKey() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-service-tunnel-xpc-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let secrets = ServiceHostTestSecretStore()
    let manager = TestServiceTunnelManager()
    let factory = TestServiceTunnelFactory(managers: [manager])
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.2.0",
        dataRootURL: root,
        executionAppServer: unavailable,
        supervisorAppServer: unavailable,
        catalogAppServer: unavailable,
        clientInfo: .bridge(version: "tunnel-xpc-tests"),
        appBundleURL: nil
      ),
      secretStore: secrets,
      randomBytes: { count in Data(repeating: 0x42, count: count) },
      tunnelFactory: factory
    )
    _ = try await composition.startLocalMCP()
    let pair = xpcClient(composition: composition)
    let client = pair.0
    let listener = pair.1
    addTeardownBlock {
      listener.invalidate()
      await client.invalidate()
      await composition.shutdown()
      try? FileManager.default.removeItem(at: root)
    }

    let tunnelID = validTunnelID(suffix: "e")
    let runtimeKey = "runtime_key_xpc_test_only"
    let localSecretData = try secrets.load(ServiceMCPSecretProvider.reference)
    let localSecret = try XCTUnwrap(String(data: localSecretData, encoding: .utf8))
    XCTAssertEqual(localSecret.utf8.count, 43)

    do {
      _ = try await client.configureTunnel(
        IPCTunnelConfigurationRequest(
          tunnelID: "invalid-tunnel-id",
          runtimeKey: runtimeKey
        )
      )
      XCTFail("Expected the invalid Tunnel ID to be rejected")
    } catch {
      guard case .remoteError(let remote) = error as? BridgeServiceIPCCodecError else {
        return XCTFail("Expected a bounded remote error")
      }
      XCTAssertEqual(remote.code, "invalid_tunnel_configuration")
      XCTAssertFalse(remote.message.contains(runtimeKey))
      XCTAssertFalse(String(describing: error).contains(runtimeKey))
    }

    let configured = try await client.configureTunnel(
      IPCTunnelConfigurationRequest(tunnelID: tunnelID, runtimeKey: runtimeKey)
    )
    XCTAssertEqual(factory.localMCPHeaderSecrets(), [localSecret])
    XCTAssertEqual(configured.tunnelID, tunnelID)
    XCTAssertEqual(configured.lifecycle, "ready")
    XCTAssertFalse(String(describing: configured).contains(runtimeKey))

    let serviceStatus = try await client.status()
    XCTAssertEqual(serviceStatus.tunnel.tunnelID, tunnelID)
    XCTAssertTrue(serviceStatus.tunnel.acceptsRemoteSubmissions)
    XCTAssertFalse(String(describing: serviceStatus).contains(runtimeKey))
    XCTAssertEqual(
      String(
        data: try secrets.load(ServiceTunnelController.runtimeKeyReference),
        encoding: .utf8
      ),
      runtimeKey
    )

    try await client.disconnectTunnel()
    let disconnectedStatus = try await client.status()
    XCTAssertFalse(disconnectedStatus.tunnel.enabled)
    try await client.clearTunnel()
    let clearedStatus = try await client.status()
    XCTAssertFalse(clearedStatus.tunnel.configured)
  }

  func testUnexpectedFailureRestartsWithoutStoppingTheLocalService() async throws {
    let fixture = try await makeTunnelFixture(self)
    let first = TestServiceTunnelManager()
    let replacement = TestServiceTunnelManager()
    let factory = TestServiceTunnelFactory(managers: [first, replacement])
    let controller = ServiceTunnelController(
      settings: fixture.settings,
      runtimeStatus: fixture.runtimeStatus,
      secretStore: fixture.secrets,
      factory: factory,
      monitorInterval: .milliseconds(10),
      restartDelays: [.milliseconds(10)]
    )
    await controller.bootstrap(
      localMCPURL: localMCPURL(port: 43_214),
      localMCPHeaderSecret: localMCPSecret
    )
    _ = try await controller.configure(
      tunnelID: validTunnelID(suffix: "d"),
      runtimeKey: "runtime_key_fixture_restart"
    )

    await first.fail(actionRequired: false)
    try await waitUntil(timeout: .seconds(3)) {
      let startCount = await replacement.startCount()
      return factory.makeCount() == 2 && startCount == 1
    }

    let status = await controller.status()
    let firstStopCount = await first.stopCount()
    XCTAssertEqual(status.lifecycle, .ready)
    XCTAssertTrue(status.acceptsRemoteSubmissions)
    XCTAssertFalse(status.actionRequired)
    XCTAssertEqual(firstStopCount, 1)
    let runtime = await fixture.runtimeStatus.current()
    XCTAssertEqual(runtime.tunnelState, "ready")
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }
}

private struct TunnelControllerFixture {
  let root: URL
  let secrets: ServiceHostTestSecretStore
  let settings: ServiceSettings
  let runtimeStatus: ServiceRuntimeStatus
}

private func makeTunnelFixture(
  _ testCase: XCTestCase
) async throws -> TunnelControllerFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-service-tunnel-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  let paths = try ServiceDataPaths.prepare(at: root)
  let store = try SimpleServiceStore(path: paths.databaseURL.path)
  let secrets = ServiceHostTestSecretStore()
  let fixture = TunnelControllerFixture(
    root: root,
    secrets: secrets,
    settings: ServiceSettings(store: store),
    runtimeStatus: ServiceRuntimeStatus()
  )
  testCase.addTeardownBlock {
    try? FileManager.default.removeItem(at: fixture.root)
  }
  return fixture
}

private func validTunnelID(suffix: Character) -> String {
  "tunnel_" + String(repeating: String(suffix), count: 32)
}

private let localMCPSecret = String(repeating: "A", count: 43)

private func localMCPURL(port: Int) -> URL {
  URL(string: "http://127.0.0.1:\(port)/mcp")!
}

private actor TestServiceTunnelManager: ServiceTunnelManaging {
  private var lifecycle = TunnelLifecycle.stopped
  private var starts = 0
  private var stops = 0
  private var actionRequired = false

  func start() async throws {
    starts += 1
    lifecycle = .ready
  }

  func stop() async {
    stops += 1
    lifecycle = .stopped
  }

  func state() async -> TunnelLifecycle {
    lifecycle
  }

  func acceptsRemoteSubmissions() async -> Bool {
    lifecycle == .ready && !actionRequired
  }

  func diagnostics() async -> TunnelDiagnostics {
    TunnelDiagnostics(
      standardOutput: "",
      standardError: "",
      wasTruncated: false,
      actionRequired: actionRequired
    )
  }

  func startCount() -> Int {
    starts
  }

  func stopCount() -> Int {
    stops
  }

  func fail(actionRequired: Bool) {
    lifecycle = .failed
    self.actionRequired = actionRequired
  }
}

private final class TestServiceTunnelFactory: ServiceTunnelManagerBuilding,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let available: Bool
  private let managers: [TestServiceTunnelManager]
  private var index = 0
  private var ports: [Int] = []
  private var headerSecrets: [String] = []

  init(
    helperAvailable: Bool = true,
    managers: [TestServiceTunnelManager]
  ) {
    available = helperAvailable
    self.managers = managers
  }

  func helperAvailable() -> Bool {
    available
  }

  func make(
    tunnelID _: TunnelID,
    runtimeKeyReference _: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any ServiceTunnelManaging {
    try lock.withLock {
      guard available, index < managers.count else {
        throw ServiceTunnelError.helperUnavailable
      }
      let manager = managers[index]
      index += 1
      headerSecrets.append(localMCPHeaderSecret)
      if let port = localMCPURL.port {
        ports.append(port)
      }
      return manager
    }
  }

  func makeCount() -> Int {
    lock.withLock { index }
  }

  func localMCPPorts() -> [Int] {
    lock.withLock { ports }
  }

  func localMCPHeaderSecrets() -> [String] {
    lock.withLock { headerSecrets }
  }
}
