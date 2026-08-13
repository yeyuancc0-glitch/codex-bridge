import BridgeCodexRPC
import BridgeDomain
import BridgePresentation
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopOnboardingServiceTests: XCTestCase {
  func testLocalDevelopmentFlowPersistsProjectPolicyAndTestsMCPBeforeCompletion() async throws {
    let root = temporaryDirectory()
    let dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
    let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let project = RegisteredProject(
      id: ProjectID(rawValue: "prj_onboarding"),
      name: "Project",
      primaryRoot: try RegisteredRoot(capturing: projectDirectory),
      repositoryRoot: try RegisteredRoot(capturing: projectDirectory),
      accessPolicy: .init(),
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let backend = OnboardingTestBackend(project: ProjectSummaryDTO(project: project))
    let secrets = OnboardingTestSecretStore()
    let service = DesktopOnboardingService(
      dataDirectoryURL: dataDirectory,
      backend: backend,
      system: OnboardingTestSystemService(),
      capabilities: PassingCapabilityInspector(),
      secretStore: secrets
    )
    _ = await service.stateUpdates()
    _ = try await waitFor(service) { !$0.isBusy }

    try await service.handle(.advance)
    try await service.handle(.advance)
    try await service.handle(.advance)
    try await service.handle(.selectConnectionMode(.localDevelopment))
    try await service.handle(.advance)
    try await service.handle(.advance)
    try await service.handle(.addProject)
    try await service.handle(.advance)
    try await service.handle(
      .setSecurityDefaults(write: .localApproval, network: .denied)
    )
    try await service.handle(.advance)
    try await service.handle(.testConnection)
    try await service.handle(.advance)
    try await service.handle(.finish)

    let presentation = await service.currentPresentation()
    XCTAssertTrue(presentation.isFinished)
    XCTAssertEqual(presentation.currentStep, .completion)
    let didStartMCP = await backend.didStartMCP
    let didTestMCP = await backend.didTestMCP
    let updatedPolicy = await backend.updatedPolicy
    XCTAssertTrue(didStartMCP)
    XCTAssertTrue(didTestMCP)
    XCTAssertEqual(
      updatedPolicy,
      ProjectAccessPolicy(
        read: .allowed,
        write: .requiresLocalApproval,
        network: .denied
      )
    )
    let record = try DesktopOnboardingStore(directoryURL: dataDirectory).load()
    XCTAssertTrue(record.completed)
    XCTAssertTrue(record.connectionTestSucceeded)
    XCTAssertEqual(record.projectID, project.id.rawValue)
    XCTAssertTrue(secrets.references.contains(where: { $0.hasPrefix("mcp-path-secret.") }))
    await service.shutdown()
  }

  private func waitFor(
    _ service: DesktopOnboardingService,
    predicate: (OnboardingPresentation) -> Bool
  ) async throws -> OnboardingPresentation {
    for _ in 0..<100 {
      let presentation = await service.currentPresentation()
      if predicate(presentation) { return presentation }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw OnboardingTestError.timeout
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-onboarding-service-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

private enum OnboardingTestError: Error {
  case mcpNotStarted
  case timeout
}

private actor OnboardingTestBackend: DesktopOnboardingBackend {
  let project: ProjectSummaryDTO
  private(set) var updatedPolicy: ProjectAccessPolicy?
  private(set) var didStartMCP = false
  private(set) var didTestMCP = false

  init(project: ProjectSummaryDTO) {
    self.project = project
  }

  func onboardingProject() -> ProjectSummaryDTO? { nil }
  func registerOnboardingProject() -> ProjectSummaryDTO? { project }

  func updateOnboardingProjectPolicy(
    projectID: ProjectID,
    policy: ProjectAccessPolicy
  ) throws {
    guard projectID == project.id else { throw ProjectRegistryError.unknownProject }
    updatedPolicy = policy
  }

  func startLocalMCP(authentication: DesktopMCPAuthentication) {
    guard case .path(let secret) = authentication, secret.utf8.count == 43 else { return }
    didStartMCP = true
  }

  func testLocalMCPConnection() throws {
    guard didStartMCP else { throw OnboardingTestError.mcpNotStarted }
    didTestMCP = true
  }
}

private struct PassingCapabilityInspector: DesktopSystemCapabilityInspecting {
  func inspect() -> DesktopSystemInspection {
    DesktopSystemInspection(
      checks: [
        OnboardingCheckPresentation(
          id: "macos",
          title: "macOS",
          detail: "ready",
          status: .ready
        ),
        OnboardingCheckPresentation(
          id: "app-server",
          title: "app-server",
          detail: "ready",
          status: .ready
        ),
        OnboardingCheckPresentation(
          id: "tunnel-helper",
          title: "Tunnel helper",
          detail: "development warning",
          status: .warning
        ),
      ],
      account: GetAccountResponse(
        account: CodexAccount(type: "chatgpt", planType: "plus"),
        requiresOpenaiAuth: true
      ),
      client: nil
    )
  }
}

@MainActor
private final class OnboardingTestSystemService: DesktopSystemServing {
  func selectProjectDirectory() async -> URL? { nil }
  func open(_: URL) -> Bool { true }
  func copyToPasteboard(_: String) -> Bool { true }
  func showMainWindow() {}
  func terminateApplication() {}
}

private final class OnboardingTestSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SecretReference: Data] = [:]

  var references: [String] {
    lock.withLock { values.keys.map(\.rawValue) }
  }

  func store(_ secret: Data, for reference: SecretReference) {
    lock.withLock { values[reference] = secret }
  }

  func load(_ reference: SecretReference) throws -> Data {
    try lock.withLock {
      guard let value = values[reference] else { throw SecretStoreError.notFound }
      return value
    }
  }

  func remove(_ reference: SecretReference) {
    lock.withLock { values[reference] = nil }
  }
}
