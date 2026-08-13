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
    try await backend.startLocalMCP(
      authentication: .path(secret: String(repeating: "a", count: 43)))
    try await backend.testLocalMCPConnection()

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
