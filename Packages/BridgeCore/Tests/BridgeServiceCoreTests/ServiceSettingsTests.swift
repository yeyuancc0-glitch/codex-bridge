import BridgeServiceCore
import XCTest

final class ServiceSettingsTests: XCTestCase {
  func testDeepSeekPermissionModeDefaultsToWorkspaceWriteAndPersistsReadOnly() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    let defaultMode = try await settings.deepSeekHarnessDefaultPermissionMode()
    XCTAssertEqual(defaultMode, "workspace-write")

    try await settings.setDeepSeekHarnessDefaultPermissionMode("read-only")

    let persistedMode = try await settings.deepSeekHarnessDefaultPermissionMode()
    XCTAssertEqual(persistedMode, "read-only")
  }

  func testDeepSeekPermissionModeRejectsUnsupportedValue() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    do {
      try await settings.setDeepSeekHarnessDefaultPermissionMode("danger-full-access")
      XCTFail("Expected unsupported DeepSeek permission mode to fail.")
    } catch ServiceStoreError.invalidArgument {}
  }
}
