import BridgeCodexRPC
import BridgeDirectCommand
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import BridgeServiceHost
import Darwin
import MCP
import XCTest

final class BridgeServiceHostTests: XCTestCase {
  func testDataPathsCreatePrivateRootAndRejectUnsafeExistingRoots() throws {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "bridge-service-path-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }

    let privateRoot = parent.appending(path: "private", directoryHint: .isDirectory)
    let paths = try ServiceDataPaths.prepare(at: privateRoot)
    XCTAssertEqual(try fileMode(paths.rootURL), 0o700)
    XCTAssertEqual(try fileMode(paths.supervisorScratchURL), 0o700)
    XCTAssertEqual(try fileMode(paths.tunnelRuntimeURL), 0o700)
    XCTAssertEqual(paths.databaseURL.lastPathComponent, "service.sqlite")

    let permissive = parent.appending(path: "permissive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: permissive.path
    )
    XCTAssertThrowsError(try ServiceDataPaths.prepare(at: permissive)) { error in
      XCTAssertEqual(error as? ServiceDataPathsError, .insecureDirectory)
    }

    let target = parent.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: target.path
    )
    let symlink = parent.appending(path: "link", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    XCTAssertThrowsError(try ServiceDataPaths.prepare(at: symlink)) { error in
      XCTAssertEqual(error as? ServiceDataPathsError, .insecureDirectory)
    }
  }

  func testMCPSecretPersistsAndRotationUsesASeparateRandomValue() async throws {
    let store = ServiceHostTestSecretStore()
    let first = ServiceMCPSecretProvider(
      store: store,
      randomBytes: { Data(repeating: 0x11, count: $0) }
    )
    let initial = try await first.secret()
    XCTAssertEqual(initial.utf8.count, 43)
    XCTAssertFalse(initial.contains("="))

    let reopened = ServiceMCPSecretProvider(
      store: store,
      randomBytes: { Data(repeating: 0x22, count: $0) }
    )
    let reopenedSecret = try await reopened.secret()
    XCTAssertEqual(reopenedSecret, initial)
    let rotated = try await reopened.rotate()
    XCTAssertNotEqual(rotated, initial)
    let reloaded = try await first.secret()
    XCTAssertEqual(reloaded, rotated)
  }

  func testCompositionServesReadOnlyThenFullMCPWithoutChangingSecret()
    async throws
  {
    let fixture = try await makeServiceHostFixture(self, startMCP: true)
    let storedReadOnlyEndpoint = await fixture.composition.endpoint()
    let readOnlyEndpoint = try XCTUnwrap(storedReadOnlyEndpoint)
    let storedSecret = try fixture.secrets.load(ServiceMCPSecretProvider.reference)
    let secret = try XCTUnwrap(String(data: storedSecret, encoding: .utf8))
    let readOnlyClient = try await connectMCP(
      endpoint: readOnlyEndpoint.localURL,
      secret: secret
    )
    defer { Task { await readOnlyClient.disconnect() } }

    let readOnlyTools = try await readOnlyClient.listTools()
    XCTAssertEqual(readOnlyTools.tools.count, 13)
    XCTAssertFalse(
      readOnlyTools.tools.contains(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )

    let fullEndpoint = try await fixture.composition.setExposureMode(.full)
    let fullClient = try await connectMCP(
      endpoint: fullEndpoint.localURL,
      secret: secret
    )
    defer { Task { await fullClient.disconnect() } }
    let fullTools = try await fullClient.listTools()
    XCTAssertEqual(fullTools.tools.count, 26)
    XCTAssertTrue(
      fullTools.tools.contains(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )

    XCTAssertEqual(secret.utf8.count, 43)
  }

  func testCompositionRestartMarksInFlightTaskUnknown() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-service-restart-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let secrets = ServiceHostTestSecretStore()
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    let configuration = ServiceCompositionConfiguration(
      appVersion: "0.2.0",
      dataRootURL: root,
      executionAppServer: unavailable,
      supervisorAppServer: unavailable,
      catalogAppServer: unavailable,
      clientInfo: .bridge(version: "restart-tests")
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try await ServiceComposition.make(
      configuration: configuration,
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x33, count: $0) }
    )
    let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await first.projects.register(
      name: "Restart Project",
      rootURL: projectRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .denied
      )
    )
    let submitted = try await first.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Exercise restart behavior.",
        executionModel: "fixture",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    _ = try await first.tasks.begin(taskID: submitted.task.id)
    await first.shutdown()

    let reopened = try await ServiceComposition.make(
      configuration: configuration,
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x44, count: $0) }
    )
    defer { Task { await reopened.shutdown() } }
    let storedTask = try await reopened.tasks.task(id: submitted.task.id)
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.state.status, ServiceTaskStatus.unknown)
    let activeWriteTask = try await reopened.tasks.activeWriteTask(projectID: project.id)
    XCTAssertEqual(activeWriteTask?.id, submitted.task.id)
  }

  func testAnonymousXPCClientRegistersAndListsAProject() async throws {
    let fixture = try await makeServiceHostFixture(self, startMCP: true)
    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let status = try await client.status()
    XCTAssertEqual(status.status.mcpState, "ready")
    XCTAssertEqual(status.status.tunnelState, "stopped")
    XCTAssertEqual(status.exposureMode, .readOnly)
    XCTAssertNotNil(status.localMCPURL)

    let projectRoot = fixture.root.appending(path: "XPCProject", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let registered = try await client.registerProject(
      IPCProjectRegistrationRequest(
        name: "XPC Project",
        absolutePath: projectRoot.path,
        writePermission: ProjectPermission.allowed.rawValue
      )
    )
    XCTAssertEqual(registered.name, "XPC Project")
    XCTAssertEqual(registered.capabilities.write, ProjectPermission.allowed.rawValue)

    let projects = try await client.projects()
    XCTAssertEqual(projects.map(\.projectID), [registered.projectID])
    XCTAssertFalse(String(describing: projects).contains(projectRoot.path))

    try await client.setExposureMode(.full)
    let storedEndpoint = await fixture.composition.endpoint()
    let endpoint = try XCTUnwrap(storedEndpoint)
    let secretData = try fixture.secrets.load(ServiceMCPSecretProvider.reference)
    let secret = try XCTUnwrap(String(data: secretData, encoding: .utf8))
    let mcpClient = try await connectMCP(endpoint: endpoint.localURL, secret: secret)
    defer { Task { await mcpClient.disconnect() } }
    let tools = try await mcpClient.listTools()
    XCTAssertEqual(tools.tools.count, 26)

    try await client.removeProject(projectID: registered.projectID)
    let remainingProjects = try await client.projects()
    XCTAssertTrue(remainingProjects.isEmpty)
  }

  func testXPCWorkspaceCommandsRoundTripThroughTheService() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let projectRoot = fixture.root.appending(path: "CommandProject", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let registered = try await client.registerProject(
      IPCProjectRegistrationRequest(
        name: "Command Project",
        absolutePath: projectRoot.path,
        writePermission: ProjectPermission.requiresLocalApproval.rawValue
      )
    )

    let initial = try await client.projectCommands(projectID: registered.projectID)
    XCTAssertEqual(initial.directWorkspace?.commandMode, "safe")
    XCTAssertTrue(initial.directWorkspace?.commands.isEmpty ?? false)

    let updated = try await client.updateProjectCommands(
      projectID: registered.projectID,
      commands: [
        IPCWorkspaceCommand(
          commandID: "wcmd-xpc",
          name: "XPC Tests",
          executable: "Scripts/with-xcode.sh",
          arguments: ["swift", "test"],
          requiresNetwork: false,
          risk: "normal"
        )
      ],
      commandBlacklist: [
        IPCBlacklistRule(ruleID: "blk-xpc", executable: "rm")
      ]
    )
    XCTAssertEqual(updated.directWorkspace?.commands.map(\.commandID), ["wcmd-xpc"])
    XCTAssertEqual(updated.directWorkspace?.commandBlacklist.map(\.ruleID), ["blk-xpc"])
    XCTAssertEqual(updated.directWorkspace?.commandMode, "safe")

    let withMode = try await client.setProjectCommandMode(
      projectID: registered.projectID,
      commandMode: "full"
    )
    XCTAssertEqual(withMode.directWorkspace?.commandMode, "full")
    XCTAssertEqual(withMode.directWorkspace?.commands.map(\.commandID), ["wcmd-xpc"])
    XCTAssertEqual(withMode.capabilities.write, ProjectPermission.requiresLocalApproval.rawValue)

    let preservedMode = try await client.updateProjectCommands(
      projectID: registered.projectID,
      commands: [
        IPCWorkspaceCommand(
          commandID: "wcmd-xpc-2",
          name: "XPC Tests 2",
          executable: "pwd",
          arguments: [],
          requiresNetwork: false,
          risk: "normal"
        )
      ],
      commandBlacklist: []
    )
    XCTAssertEqual(preservedMode.directWorkspace?.commandMode, "full")

    let reloaded = try await client.projectCommands(projectID: registered.projectID)
    XCTAssertEqual(reloaded.directWorkspace?.commandMode, "full")
    XCTAssertEqual(reloaded.directWorkspace?.commands.map(\.name), ["XPC Tests 2"])
    XCTAssertTrue(reloaded.directWorkspace?.commandBlacklist.isEmpty ?? false)
  }

  func testXPCDirectApprovalsRoundTripThroughTheService() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let initial = try await client.pendingDirectApprovals()
    XCTAssertTrue(initial.isEmpty)

    let approvalID = await fixture.composition.application.approvals.request(
      projectID: "prj-approval",
      kind: .command,
      summary: "Run swift test",
      payloadDigest: "digest-xpc",
      clientRequestID: "req-xpc-1"
    )
    let pending = try await client.pendingDirectApprovals()
    XCTAssertEqual(pending.map(\.approvalID), [approvalID])
    XCTAssertEqual(pending[0].kind, "command")

    let approveResult = try await client.approveDirectApproval(approvalID: approvalID)
    XCTAssertTrue(approveResult)
    let afterApprove = try await client.pendingDirectApprovals()
    XCTAssertTrue(afterApprove.isEmpty)

    let secondID = await fixture.composition.application.approvals.request(
      projectID: "prj-approval",
      kind: .fileWrite,
      summary: "Write README.md",
      payloadDigest: "digest-xpc-2",
      clientRequestID: nil
    )
    let denyResult = try await client.denyDirectApproval(approvalID: secondID)
    XCTAssertTrue(denyResult)
    let afterDeny = try await client.pendingDirectApprovals()
    XCTAssertTrue(afterDeny.isEmpty)
    let consumed = await fixture.composition.application.approvals.consume(
      payloadDigest: "digest-xpc-2",
      clientRequestID: nil
    )
    XCTAssertFalse(consumed)
  }

  func testTunnelDisconnectDoesNotStopRunningDirectCommandSession() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let projectID = ProjectID(rawValue: "prj-tunnel-direct")
    let session = try await fixture.composition.application.directCommands.launch(
      sessionID: "dcmd-tunnel",
      projectID: projectID,
      argv: ["/bin/sh", "-c", "sleep 1; echo survived-tunnel-disconnect"],
      workingDirectory: nil,
      requiresNetwork: false,
      usePTY: false,
      timeout: .seconds(30)
    )
    XCTAssertEqual(session.status, "running")

    // Tunnel disconnecting must only block new remote submissions, never touch running local work.
    try await fixture.composition.disconnectTunnel()
    try await fixture.composition.tunnelStatus()

    let deadline = Date().addingTimeInterval(10)
    var finished: DirectCommandSession?
    while Date() < deadline {
      if let current = await fixture.composition.application.directCommands.snapshot(
        sessionID: "dcmd-tunnel"
      ), current.status == "ended" {
        finished = current
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let result = try XCTUnwrap(finished)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.output.tail.contains("survived-tunnel-disconnect"))
  }

  func testXPCModelPreferencesRoundTripThroughTheService() async throws {
    let catalog = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", xpcModelCatalogScript]
    )
    let fixture = try await makeServiceHostFixture(self, catalogAppServer: catalog)
    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let defaults = try await client.modelCatalog()
    let preferences = defaults.preferences
    XCTAssertEqual(preferences.executionModel, "execution-model")
    XCTAssertEqual(preferences.executionEffort, "high")
    XCTAssertEqual(preferences.supervisorModel, "gpt-5.6-luna")
    XCTAssertEqual(preferences.supervisorEffort, "medium")
    XCTAssertEqual(preferences.supervisorEnabled, true)
    XCTAssertEqual(preferences.accessMode, "request-approval")
    XCTAssertEqual(preferences.fastModeEnabled, false)

    let configured = IPCModelPreferences(
      executionModel: "gpt-5.6-luna",
      executionEffort: "medium",
      supervisorModel: "execution-model",
      supervisorEffort: "high",
      accessMode: "auto-review",
      fastModeEnabled: true
    )
    try await client.setModelPreferences(configured)
    let reloaded = try await client.modelCatalog()
    XCTAssertEqual(reloaded.preferences, configured)

    try await client.setSupervisorEnabled(false)
    let disabled = try await client.modelCatalog()
    XCTAssertEqual(disabled.preferences.supervisorEnabled, false)

    try await client.setSupervisorEnabled(true)
    let reenabled = try await client.modelCatalog()
    XCTAssertEqual(reenabled.preferences.supervisorEnabled, true)
  }

  func testIPCCodecRejectsOversizeAndMismatchedResponses() throws {
    let oversized = Data(repeating: 0x41, count: BridgeServiceIPC.maximumMessageBytes + 1)
    XCTAssertThrowsError(try BridgeServiceIPCCodec.decodeRequest(oversized)) { error in
      XCTAssertEqual(error as? BridgeServiceIPCCodecError, .messageTooLarge)
    }

    let response = try BridgeServiceIPCCodec.success(
      requestID: "request-one",
      payload: IPCMutationResponse()
    )
    XCTAssertThrowsError(
      try BridgeServiceIPCCodec.decodeResponse(
        IPCMutationResponse.self,
        data: response,
        requestID: "request-two"
      )
    ) { error in
      XCTAssertEqual(error as? BridgeServiceIPCCodecError, .requestMismatch)
    }
  }

  func testProcessOptionsAreStrictAndDoNotAcceptRelativeDataRoots() throws {
    let options = try ServiceProcessOptions.parse([
      "--foreground",
      "--data-root",
      "/private/tmp/codex-bridge-test",
    ])
    XCTAssertTrue(options.foreground)
    XCTAssertEqual(options.dataRootURL.path, "/private/tmp/codex-bridge-test")
    XCTAssertThrowsError(
      try ServiceProcessOptions.parse(["--data-root", "relative/path"])
    ) { error in
      XCTAssertEqual(error as? ServiceProcessArgumentError, .invalidDataRoot)
    }
    XCTAssertThrowsError(try ServiceProcessOptions.parse(["--unknown"])) { error in
      XCTAssertEqual(
        error as? ServiceProcessArgumentError,
        .unknownArgument("--unknown")
      )
    }
  }

  private func connectMCP(endpoint: URL, secret: String) async throws -> Client {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let transport = HTTPClientTransport(
      endpoint: endpoint,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1,
      requestModifier: { request in
        var request = request
        request.setValue(
          secret,
          forHTTPHeaderField: MCPHTTPConfiguration.tunnelAuthenticationHeader
        )
        return request
      }
    )
    let client = Client(
      name: "service-host-tests",
      version: "1",
      configuration: .strict
    )
    _ = try await client.connect(transport: transport)
    return client
  }
}

private var xpcModelCatalogScript: String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r request
  case "$request" in *'"method":"model/list"'*) ;; *) exit 11 ;; esac
  printf '%s\n' '{"id":2,"result":{"data":[{"id":"execution-model","model":"execution-model","displayName":"Execution","description":"Execution","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","isDefault":true},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
  sleep 1
  """#
}
