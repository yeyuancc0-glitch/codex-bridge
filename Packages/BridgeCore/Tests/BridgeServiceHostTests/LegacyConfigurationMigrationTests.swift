import BridgeLegacyImport
import BridgeServiceCore
import BridgeServiceHost
import XCTest

final class LegacyConfigurationMigrationTests: XCTestCase {
  private static let migrationFailure =
    "Migration: Legacy configuration import failed; existing Service data was left unchanged."

  func testCompositionImportsLegacyConfigurationBeforeExposingServiceComponents() async throws {
    let fixture = try ServiceLegacyImportFixture(testCase: self)
    let project = try fixture.project()
    let tunnelID = "tunnel_" + String(repeating: "a", count: 32)
    try fixture.writeRepository(project: project)
    try fixture.writeOnboarding(tunnelID: tunnelID)
    let repositoryDigest = try fixture.digest(of: fixture.repositoryURL)
    let onboardingDigest = try fixture.digest(of: fixture.onboardingURL)

    let (composition, secrets) = try await fixture.makeComposition(
      testCase: self,
      legacyDataRootURL: fixture.legacyRoot
    )
    let legacyImportReport = await composition.legacyImportReport
    let report = try XCTUnwrap(legacyImportReport)
    let storedProject = try await composition.store.project(id: project.id)
    let storedTunnelID = try await composition.settings.string(for: .tunnelID)
    let storedTunnelEnabled = try await composition.settings.string(for: .tunnelEnabled)
    let runtime = await composition.runtimeStatus.current()
    let endpoint = await composition.endpoint()

    XCTAssertEqual(report.status, .imported)
    XCTAssertEqual(report.insertedProjectIDs, [project.id])
    XCTAssertEqual(storedProject?.name, project.name)
    XCTAssertEqual(storedProject?.root.canonicalPath, project.primaryRoot.canonicalPath)
    XCTAssertEqual(storedProject?.accessPolicy, project.accessPolicy)
    XCTAssertEqual(storedTunnelID, tunnelID)
    XCTAssertEqual(storedTunnelEnabled, "0")
    XCTAssertTrue(runtime.degradations.isEmpty)
    XCTAssertNil(endpoint)
    XCTAssertThrowsError(try secrets.load(ServiceTunnelController.runtimeKeyReference))
    XCTAssertEqual(try fixture.digest(of: fixture.repositoryURL), repositoryDigest)
    XCTAssertEqual(try fixture.digest(of: fixture.onboardingURL), onboardingDigest)
  }

  func testCompositionDegradesWithoutLeakingDetailsWhenLegacyImportFails() async throws {
    let fixture = try ServiceLegacyImportFixture(testCase: self)
    let project = try fixture.project()
    try fixture.writeRepository(project: project)
    try fixture.writeOnboarding(
      tunnelID: "tunnel_" + String(repeating: "b", count: 32)
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o644)],
      ofItemAtPath: fixture.onboardingURL.path
    )

    let (composition, _) = try await fixture.makeComposition(
      testCase: self,
      legacyDataRootURL: fixture.legacyRoot
    )
    let runtime = await composition.runtimeStatus.current()
    let projects = try await composition.store.projects()
    let tunnelID = try await composition.settings.string(for: .tunnelID)
    let marker = try await composition.store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )

    let legacyImportReport = await composition.legacyImportReport
    XCTAssertNil(legacyImportReport)
    XCTAssertEqual(runtime.degradations, [Self.migrationFailure])
    XCTAssertFalse(runtime.degradations[0].contains(fixture.root.path))
    XCTAssertFalse(runtime.degradations[0].contains("onboarding.json"))
    XCTAssertTrue(projects.isEmpty)
    XCTAssertNil(tunnelID)
    XCTAssertFalse(marker)
  }

  func testNilLegacyRootDisablesLegacyReadsAndProducesNoMigrationState() async throws {
    let fixture = try ServiceLegacyImportFixture(testCase: self)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: fixture.legacyRoot.path
    )

    let (composition, _) = try await fixture.makeComposition(
      testCase: self,
      legacyDataRootURL: nil
    )
    let runtime = await composition.runtimeStatus.current()
    let marker = try await composition.store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )

    let projects = try await composition.store.projects()

    let legacyImportReport = await composition.legacyImportReport
    XCTAssertNil(legacyImportReport)
    XCTAssertTrue(runtime.degradations.isEmpty)
    XCTAssertFalse(marker)
    XCTAssertTrue(projects.isEmpty)
  }

  func testRepeatedCompositionStartupIsIdempotentAndKeepsNewServiceSettings() async throws {
    let fixture = try ServiceLegacyImportFixture(testCase: self)
    let project = try fixture.project()
    let oldTunnelID = "tunnel_" + String(repeating: "c", count: 32)
    let newTunnelID = "tunnel_" + String(repeating: "d", count: 32)
    try fixture.writeRepository(project: project)
    try fixture.writeOnboarding(tunnelID: oldTunnelID)

    let (first, _) = try await fixture.makeComposition(
      testCase: self,
      legacyDataRootURL: fixture.legacyRoot
    )
    let firstImportStatus = await first.legacyImportReport?.status
    XCTAssertEqual(firstImportStatus, .imported)
    try await first.settings.set(newTunnelID, for: .tunnelID)
    await first.shutdown()

    let (second, _) = try await fixture.makeComposition(
      testCase: self,
      legacyDataRootURL: fixture.legacyRoot
    )
    let projects = try await second.store.projects()
    let storedTunnelID = try await second.settings.string(for: .tunnelID)
    let storedTunnelEnabled = try await second.settings.string(for: .tunnelEnabled)

    let secondImportStatus = await second.legacyImportReport?.status
    XCTAssertEqual(secondImportStatus, .alreadyCompleted)
    XCTAssertEqual(projects.map(\.id), [project.id])
    XCTAssertEqual(storedTunnelID, newTunnelID)
    XCTAssertEqual(storedTunnelEnabled, "0")
  }
}
