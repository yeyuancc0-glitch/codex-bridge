import BridgeCodexRPC
import Foundation
import XCTest

final class AppServerProcessWindowsTests: XCTestCase {
  func testTypedWorkflowOverNativeWindowsStdio() async throws {
    let fixture = try fixtureURL()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex bridge rpc \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let client = CodexAppServerClient(
      configuration: AppServerConfiguration(
        executableURL: fixture,
        arguments: ["--app-server"],
        currentDirectoryURL: directory
      ),
      defaultTimeoutNanoseconds: 5_000_000_000
    )

    try await client.start()
    do {
      let initialized = try await client.initialize(
        clientInfo: CodexClientInfo(
          name: "codex_bridge_windows_tests",
          title: "Codex Bridge Windows Tests",
          version: "1"
        )
      )
      XCTAssertEqual(initialized.platformFamily, "windows")
      XCTAssertEqual(initialized.platformOS, "windows")

      let thread = try await client.startThread(
        ThreadStartParams(
          cwd: directory.path,
          sandbox: .workspaceWrite,
          approvalPolicy: .never,
          ephemeral: true,
          model: "fixture-model"
        )
      )
      XCTAssertEqual(thread.thread.id, "thread-1")
      XCTAssertEqual(thread.thread.cwd, directory.path)
      XCTAssertEqual(thread.cwd, directory.path)
      XCTAssertEqual(thread.sandbox.type, "workspaceWrite")

      let turn = try await client.startTurn(
        TurnStartParams(
          threadId: thread.thread.id,
          text: "fixture",
          sandboxPolicy: .workspaceWrite(writableRoots: [directory.path]),
          approvalPolicy: .never,
          model: "fixture-model",
          effort: "high"
        )
      )
      XCTAssertEqual(turn.turn.id, "turn-1")
      XCTAssertEqual(turn.turn.status, "inProgress")

      let steered = try await client.steerTurn(
        TurnSteerParams(
          threadId: thread.thread.id,
          expectedTurnId: turn.turn.id,
          text: "steer"
        )
      )
      XCTAssertEqual(steered.turnId, turn.turn.id)

      _ = try await client.interruptTurn(
        TurnInterruptParams(
          threadId: thread.thread.id,
          turnId: turn.turn.id
        )
      )
      await client.stop()
    } catch {
      await client.stop()
      throw error
    }
  }

  private func fixtureURL() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment["BRIDGE_WINDOWS_PROCESS_FIXTURE"] {
      let url = URL(fileURLWithPath: configured)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }

    let directory = URL(fileURLWithPath: CommandLine.arguments[0])
      .standardizedFileURL
      .deletingLastPathComponent()
    for name in [
      "windows-process-tree-fixture.exe",
      "WindowsProcessTreeFixture.exe",
    ] {
      let candidate = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    throw XCTSkip("Windows process-tree fixture was not built beside the test executable")
  }
}
