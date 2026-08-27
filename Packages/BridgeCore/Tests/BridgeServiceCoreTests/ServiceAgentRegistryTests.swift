import BridgeAgentCore
import BridgeDomain
import Darwin
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentRegistryTests: XCTestCase {
  func testExplicitRegistrationProbesAndPersistsObservedInstallation() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-fixture",
      content: "#!/bin/sh\nexit 0\n"
    )
    let counter = ProbeInvocationCounter()
    let provider = try RegistryFixtureProvider(counter: counter)
    let clock = ServiceCoreTestClock()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let registry = ServiceAgentRegistry(
      store: store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-opencode") },
      now: { clock.next() }
    )

    let record = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode",
        executablePath: executable,
        trustProfile: .managed,
        securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
        enableOnSuccess: true,
        projectRoot: fixture.firstProjectURL.path
      )
    )

    XCTAssertEqual(record.id.rawValue, "ainst-opencode")
    XCTAssertEqual(record.providerID, .openCode)
    XCTAssertEqual(record.version, "1.18.22")
    XCTAssertEqual(record.protocolRevision, "1")
    XCTAssertEqual(record.availability, .available)
    XCTAssertTrue(record.isEnabled)
    XCTAssertTrue(record.isSelectable)
    XCTAssertTrue(record.capabilities.effective.contains(.workspaceRead))
    XCTAssertEqual(record.securityProfileID?.rawValue, "controlled-readonly")
    XCTAssertEqual(record.executableIdentity.sha256.count, 64)

    let probeCount = await counter.value()
    XCTAssertEqual(probeCount, 1)
    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let persisted = try await reopened.agentInstallation(id: record.id)
    XCTAssertEqual(persisted, record)
  }

  func testRefreshDetectsReplacementWithoutExecutingProvider() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-replaced",
      content: "#!/bin/sh\necho first\n"
    )
    let counter = ProbeInvocationCounter()
    let provider = try RegistryFixtureProvider(counter: counter)
    let clock = ServiceCoreTestClock()
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-replaced") },
      now: { clock.next() }
    )
    let registered = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode replaced",
        executablePath: executable,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    try Data("#!/bin/sh\necho second\n".utf8).write(to: URL(fileURLWithPath: executable))
    XCTAssertEqual(chmod(executable, 0o700), 0)
    let refreshed = try await registry.refreshInstallationStates()
    let record = try XCTUnwrap(refreshed.first)

    XCTAssertEqual(record.id, registered.id)
    XCTAssertEqual(record.availability, .needsReview)
    XCTAssertTrue(record.isEnabled)
    XCTAssertFalse(record.isSelectable)
    XCTAssertEqual(record.capabilities, .empty)
    XCTAssertTrue(record.lastProbeError?.contains("changed") == true)
    let probeCount = await counter.value()
    XCTAssertEqual(probeCount, 1)
  }

  func testExplicitReplacementAcceptanceReprobesAndRestoresAvailability() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-accepted",
      content: "#!/bin/sh\necho original\n"
    )
    let counter = ProbeInvocationCounter()
    let provider = try RegistryFixtureProvider(counter: counter)
    let clock = ServiceCoreTestClock()
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-accepted") },
      now: { clock.next() }
    )
    let original = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode accepted",
        executablePath: executable,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    try Data("#!/bin/sh\necho replacement\n".utf8).write(to: URL(fileURLWithPath: executable))
    XCTAssertEqual(chmod(executable, 0o700), 0)
    let review = try await registry.reprobe(installationID: original.id)
    XCTAssertEqual(review.availability, .needsReview)

    let accepted = try await registry.reprobe(
      installationID: original.id,
      acceptReplacement: true
    )

    XCTAssertEqual(accepted.availability, .available)
    XCTAssertTrue(accepted.isSelectable)
    XCTAssertNotEqual(accepted.executableIdentity.sha256, original.executableIdentity.sha256)
    let probeCount = await counter.value()
    XCTAssertEqual(probeCount, 2)
  }

  func testReviewRequiredProbePersistsObservedVersionWithoutCapabilities() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-future",
      content: "#!/bin/sh\nexit 0\n"
    )
    let counter = ProbeInvocationCounter()
    let provider = try RegistryFixtureProvider(
      counter: counter,
      version: "2.0.0",
      reviewRequired: true
    )
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-future") }
    )

    let record = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode future",
        executablePath: executable,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    XCTAssertEqual(record.version, "2.0.0")
    XCTAssertEqual(record.availability, .needsReview)
    XCTAssertEqual(record.capabilities, .empty)
    XCTAssertFalse(record.isSelectable)
    XCTAssertTrue(record.lastProbeError?.contains("unsupported") == true)
  }

  func testUnavailableProbeReasonIsNotMaskedByMissingVersion() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-unavailable",
      content: "#!/bin/sh\nexit 1\n"
    )
    let provider = try RegistryFixtureProvider(
      counter: ProbeInvocationCounter(),
      unavailableReason: "Fixture failed before version negotiation."
    )
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-unavailable") }
    )

    let record = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode unavailable",
        executablePath: executable,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    XCTAssertNil(record.version)
    XCTAssertEqual(record.availability, .unavailable)
    XCTAssertEqual(record.lastProbeError, "Fixture failed before version negotiation.")
  }

  func testExecutableIdentityRejectsUnsafeModeAndDetectsInPlaceChange() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = try makeExecutable(
      directory: directory,
      name: "agent",
      content: "#!/bin/sh\necho one\n"
    )
    let first = try ServiceAgentExecutableIdentity(capturing: path)

    try Data("#!/bin/sh\necho two\n".utf8).write(to: URL(fileURLWithPath: path))
    XCTAssertEqual(chmod(path, 0o700), 0)
    let second = try ServiceAgentExecutableIdentity(capturing: path)
    XCTAssertEqual(first.inode, second.inode)
    XCTAssertNotEqual(first.sha256, second.sha256)

    XCTAssertEqual(chmod(path, 0o777), 0)
    XCTAssertThrowsError(try ServiceAgentExecutableIdentity(capturing: path))
  }

  func testArtifactReplacementRequiresReviewAndExplicitAcceptance() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      directory: fixture.rootURL,
      name: "opencode-artifact",
      content: "#!/bin/sh\nexit 0\n"
    )
    let configurationURL = fixture.rootURL.appending(path: "cordis.yml")
    try Data("sandbox: read-only\n".utf8).write(to: configurationURL)
    XCTAssertEqual(chmod(configurationURL.path, 0o600), 0)
    let counter = ProbeInvocationCounter()
    let provider = try RegistryFixtureProvider(counter: counter)
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-artifact-review") }
    )

    let registered = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode artifact",
        executablePath: executable,
        trustProfile: .managed,
        enableOnSuccess: true,
        artifacts: [
          try ServiceAgentInstallationArtifactRequest(
            role: .launchConfiguration,
            path: configurationURL.path
          )
        ]
      )
    )
    XCTAssertEqual(registered.artifacts.count, 1)

    try Data("sandbox: changed\n".utf8).write(to: configurationURL)
    XCTAssertEqual(chmod(configurationURL.path, 0o600), 0)
    let refreshed = try await registry.refreshInstallationStates()
    let review = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(review.availability, .needsReview)
    XCTAssertFalse(review.isSelectable)
    let reviewProbeCount = await counter.value()
    XCTAssertEqual(reviewProbeCount, 1)

    let accepted = try await registry.reprobe(
      installationID: registered.id,
      acceptReplacement: true
    )
    XCTAssertEqual(accepted.availability, .available)
    XCTAssertTrue(accepted.isSelectable)
    XCTAssertNotEqual(
      accepted.artifacts.first?.identity.sha256,
      registered.artifacts.first?.identity.sha256
    )
    let acceptedProbeCount = await counter.value()
    XCTAssertEqual(acceptedProbeCount, 2)
  }

  private func makeExecutable(
    directory: URL,
    name: String,
    content: String
  ) throws -> String {
    let url = directory.appending(path: name)
    try Data(content.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }
    return url.path
  }
}

private actor ProbeInvocationCounter {
  private var count = 0

  func increment() {
    count += 1
  }

  func value() -> Int {
    count
  }
}

private struct RegistryFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let counter: ProbeInvocationCounter
  let version: String
  let reviewRequired: Bool
  let unavailableReason: String?

  init(
    counter: ProbeInvocationCounter,
    version: String = "1.18.22",
    reviewRequired: Bool = false,
    unavailableReason: String? = nil
  ) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
    self.counter = counter
    self.version = version
    self.reviewRequired = reviewRequired
    self.unavailableReason = unavailableReason
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    await counter.increment()
    if let unavailableReason {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: unavailableReason
      )
    }
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: version,
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "Fixture installation is invalid."
      )
    }
    if reviewRequired {
      return AgentProbeResult(
        installation: installation,
        available: false,
        reviewRequired: true,
        capabilities: .empty,
        unavailableReason: "The fixture version is unsupported."
      )
    }
    let capabilities: Set<AgentCapability> = [
      .interrupt,
      .sessionCreate,
      .textDelta,
      .workspaceRead,
    ]
    return AgentProbeResult(
      installation: installation,
      available: true,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
