import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopMCPRuntimeTests: XCTestCase {
  func testBackendBootstrapsAndPassesRealLoopbackMCPContract() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: directory,
      system: MCPRuntimeTestSystemService()
    )

    let project = try await backend.onboardingProject()
    XCTAssertNil(project)
    let localURL = try await backend.configureOnboardingTransport(
      .local(pathSecret: String(repeating: "a", count: 43))
    )
    XCTAssertEqual(localURL.host, "127.0.0.1")
    try await backend.testOnboardingTransport()
    try await DesktopMCPRuntime.validate(
      transport: DesktopBoundedHTTPTransport(
        endpoint: localURL,
        authorization: "Bearer bounded-transport-test"
      )
    )

    await backend.shutdown()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-mcp-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

@MainActor
private final class MCPRuntimeTestSystemService: DesktopSystemServing {
  func selectProjectDirectory() async -> URL? { nil }
  func open(_: URL) -> Bool { true }
  func copyToPasteboard(_: String) -> Bool { true }
  func showMainWindow() {}
  func terminateApplication() {}
}
