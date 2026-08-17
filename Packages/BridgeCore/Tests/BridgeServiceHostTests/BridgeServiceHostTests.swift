import BridgeCodexRPC
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
    let readOnlyClient = try await connectMCP(endpoint: readOnlyEndpoint.localURL)
    defer { Task { await readOnlyClient.disconnect() } }

    let readOnlyTools = try await readOnlyClient.listTools()
    XCTAssertEqual(readOnlyTools.tools.count, 9)
    XCTAssertFalse(
      readOnlyTools.tools.contains(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )

    let fullEndpoint = try await fixture.composition.setExposureMode(.full)
    let fullClient = try await connectMCP(endpoint: fullEndpoint.localURL)
    defer { Task { await fullClient.disconnect() } }
    let fullTools = try await fullClient.listTools()
    XCTAssertEqual(fullTools.tools.count, 12)
    XCTAssertTrue(
      fullTools.tools.contains(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )

    let storedSecret = try fixture.secrets.load(ServiceMCPSecretProvider.reference)
    XCTAssertEqual(String(data: storedSecret, encoding: .utf8)?.utf8.count, 43)
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
    _ = try await first.tasks.approve(taskID: submitted.task.id)
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
    XCTAssertEqual(status.mcpState, "ready")
    XCTAssertEqual(status.tunnelState, "stopped")

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
    let mcpClient = try await connectMCP(endpoint: endpoint.localURL)
    defer { Task { await mcpClient.disconnect() } }
    let tools = try await mcpClient.listTools()
    XCTAssertEqual(tools.tools.count, 12)

    try await client.removeProject(projectID: registered.projectID)
    let remainingProjects = try await client.projects()
    XCTAssertTrue(remainingProjects.isEmpty)
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

  private func connectMCP(endpoint: URL) async throws -> Client {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let transport = HTTPClientTransport(
      endpoint: endpoint,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1
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
