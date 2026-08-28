import BridgeMCP
import Foundation
import Security

@main
struct BridgeMCPInspectorFixture {
  static func main() async throws {
    let arguments = try parseArguments()
    let secret = try makePathSecret()
    let httpConfiguration = try makeHTTPConfiguration(
      authentication: arguments.authentication,
      secret: secret
    )
    let server = MCPBridgeServer(
      appVersion: "inspector-fixture",
      service: InspectorService(),
      exposureMode: .readOnly,
      httpConfiguration: httpConfiguration,
      sessionLimits: .init(maximumSessions: 8)
    )
    let endpoint = try await server.start()
    try writeReadyEndpoint(
      endpoint.localURL,
      tunnelHeaderSecret: arguments.authentication.usesHeader ? secret : nil
    )

    while !FileManager.default.fileExists(atPath: arguments.stopFile.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    await server.stop()
  }

  private static func parseArguments() throws -> FixtureArguments {
    let arguments = CommandLine.arguments
    guard
      arguments.count == 3 || arguments.count == 5,
      arguments[1] == "--stop-file"
    else {
      throw FixtureError.invalidArguments
    }
    let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard url.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.path) else {
      throw FixtureError.invalidStopFile
    }
    let authentication = try parseAuthentication(arguments)
    return FixtureArguments(stopFile: url, authentication: authentication)
  }

  private static func parseAuthentication(_ arguments: [String]) throws
    -> FixtureAuthentication
  {
    guard arguments.count == 5 else { return .path }
    guard arguments[3] == "--authentication" else { throw FixtureError.invalidArguments }
    switch arguments[4] {
    case "tunnel-header": return .chatGPTHeader
    case "qwen-header": return .qwenHeader
    default: throw FixtureError.invalidArguments
    }
  }

  private static func makeHTTPConfiguration(
    authentication: FixtureAuthentication,
    secret: String
  ) throws -> MCPHTTPConfiguration {
    switch authentication {
    case .path:
      return try MCPHTTPConfiguration(pathSecret: secret)
    case .chatGPTHeader:
      return try MCPHTTPConfiguration(headerSecret: secret)
    case .qwenHeader:
      let credential = try MCPClientCredential(clientID: .qwenStudio, value: secret)
      let authenticator = try MCPClientCredentialAuthenticator(credentials: [credential])
      return try MCPHTTPConfiguration(clientAuthenticator: authenticator)
    }
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

  private static func writeReadyEndpoint(_ url: URL, tunnelHeaderSecret: String?) throws {
    var value = ["url": url.absoluteString]
    if let tunnelHeaderSecret {
      value["header_name"] = MCPHTTPConfiguration.tunnelAuthenticationHeader
      value["header_value"] = tunnelHeaderSecret
    }
    let data = try JSONSerialization.data(withJSONObject: value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}

private struct FixtureArguments {
  let stopFile: URL
  let authentication: FixtureAuthentication
}

private enum FixtureAuthentication {
  case path
  case chatGPTHeader
  case qwenHeader

  var usesHeader: Bool {
    self != .path
  }
}

private enum FixtureError: Error {
  case invalidArguments
  case invalidStopFile
  case randomnessUnavailable
}

private struct InspectorService: BridgeMCPServiceAPI {
  func serviceStatus(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
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

  func serviceProjects(
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

  func serviceThreads(
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

  func serviceReadThread(
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

  func serviceModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
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

  func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    guard projectID == "prj_inspector_fixture" else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return MCPProjectDetail(
      projectID: projectID,
      name: "Inspector fixture",
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "local_approval",
        network: "denied"
      ),
      gitState: "clean"
    )
  }

  func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceListSkills(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillList {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceReadSkill(
    skillName: String,
    projectID: String?,
    subpath: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillDocument {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceRunSkillAction(
    _ request: MCPRunSkillActionRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot {
    throw BridgeMCPQueryError.taskNotFound
  }

  func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectReadCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectInterruptCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    throw BridgeMCPQueryError.unavailable
  }

  func serviceDirectGitCommit(
    _ request: MCPDirectGitCommitRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectGitCommitReceipt {
    throw BridgeMCPQueryError.unavailable
  }
}
