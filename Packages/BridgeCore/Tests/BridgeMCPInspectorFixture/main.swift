import BridgeMCP
import Foundation
import Security

@main
struct BridgeMCPInspectorFixture {
  static func main() async throws {
    let stopFile = try parseStopFile()
    let secret = try makePathSecret()
    let server = MCPBridgeServer(
      appVersion: "inspector-fixture",
      queries: InspectorQueries(),
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret),
      sessionLimits: .init(maximumSessions: 8)
    )
    let endpoint = try await server.start()
    try writeReadyURL(endpoint.localURL)

    while !FileManager.default.fileExists(atPath: stopFile.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    await server.stop()
  }

  private static func parseStopFile() throws -> URL {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--stop-file" else {
      throw FixtureError.invalidArguments
    }
    let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard url.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.path) else {
      throw FixtureError.invalidStopFile
    }
    return url
  }

  private static func makePathSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw FixtureError.randomnessUnavailable
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func writeReadyURL(_ url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}

private enum FixtureError: Error {
  case invalidArguments
  case invalidStopFile
  case randomnessUnavailable
}

private struct InspectorQueries: BridgeMCPQueries {
  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "inspector-fixture",
      mcpState: "ready",
      tunnelState: "disconnected",
      codexVersion: "fixture",
      loginMode: "fixture",
      executionState: "ready",
      supervisorState: "ready",
      pendingApprovalCount: 0
    )
  }

  func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    MCPProjectPage(
      projects: [
        MCPProjectSummary(
          projectID: "prj_inspector_fixture",
          name: "Inspector fixture",
          capabilities: MCPProjectCapabilities(
            read: "allowed",
            write: "local_approval",
            network: "denied"
          ),
          gitState: "clean"
        )
      ]
    )
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    guard projectID == "prj_inspector_fixture" else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return MCPThreadPage(threads: [])
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    guard projectID == "prj_inspector_fixture" else {
      throw BridgeMCPQueryError.projectNotFound
    }
    throw BridgeMCPQueryError.threadNotFound
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    MCPModelList(
      models: [
        MCPModelSummary(
          modelID: "fixture-model",
          displayName: "Fixture Model",
          isDefault: true,
          reasoningEfforts: ["medium"]
        )
      ]
    )
  }
}
