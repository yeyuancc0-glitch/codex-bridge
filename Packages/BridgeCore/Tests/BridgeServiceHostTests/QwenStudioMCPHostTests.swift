import BridgeCodexRPC
import BridgeIPC
import BridgeMCP
import BridgeSecurity
import BridgeServiceHost
import Darwin
import Foundation
import MCP
import XCTest

final class QwenStudioMCPHostTests: XCTestCase {
  func testMCPClientXPCOperationsUseSchemaVersionFourAndRoundTrip() throws {
    XCTAssertEqual(BridgeServiceIPC.schemaVersion, 4)
    let operations: [BridgeServiceIPCOperation] = [
      .listMCPClients,
      .setMCPClientEnabled,
      .setMCPClientExposureMode,
      .exportMCPClientConfiguration,
      .rotateMCPClientCredential,
      .rotateLocalMCPEndpoint,
    ]
    for operation in operations {
      let data = try BridgeServiceIPCCodec.emptyRequest(
        operation: operation,
        requestID: "qwen-xpc-\(operation.rawValue)"
      )
      let request = try BridgeServiceIPCCodec.decodeRequest(data)
      XCTAssertEqual(request.schemaVersion, 4)
      XCTAssertEqual(request.operation, operation)
    }
  }

  func testXPCManagesQwenIndependentlyWithoutReturningSecretsInStatus() async throws {
    let root = temporaryRoot()
    let secrets = ServiceHostTestSecretStore()
    let composition = try await makeComposition(root: root, secrets: secrets)
    defer {
      Task { await composition.shutdown() }
      try? FileManager.default.removeItem(at: root)
    }
    let chatSecret = try secrets.load(ServiceMCPSecretProvider.reference)
    XCTAssertThrowsError(
      try secrets.load(ServiceMCPSecretProvider.qwenStudioReference)
    )
    let pair = xpcClient(composition: composition)
    let xpc = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await xpc.invalidate() }
    }

    let initial = try await xpc.mcpClients()
    XCTAssertEqual(initial.first { $0.clientID == MCPClientID.qwenStudio.rawValue }?.enabled, false)
    XCTAssertEqual(
      initial.first { $0.clientID == MCPClientID.qwenStudio.rawValue }?.exposureMode,
      .readOnly
    )

    try await xpc.setMCPClientEnabled(clientID: MCPClientID.qwenStudio.rawValue, enabled: true)
    try await xpc.setMCPClientExposureMode(
      clientID: MCPClientID.qwenStudio.rawValue,
      mode: .full
    )
    let enabled = try await xpc.mcpClients()
    let qwen = try XCTUnwrap(
      enabled.first { $0.clientID == MCPClientID.qwenStudio.rawValue }
    )
    XCTAssertTrue(qwen.enabled)
    XCTAssertEqual(qwen.exposureMode, .full)
    XCTAssertEqual(qwen.activeSessionCount, 0)
    XCTAssertFalse(
      String(describing: enabled).contains(String(decoding: chatSecret, as: UTF8.self))
    )

    let oldQwen = try secrets.load(ServiceMCPSecretProvider.qwenStudioReference)
    try await xpc.rotateMCPClientCredential(clientID: MCPClientID.qwenStudio.rawValue)
    let newQwen = try secrets.load(ServiceMCPSecretProvider.qwenStudioReference)
    XCTAssertNotEqual(oldQwen, newQwen)
    XCTAssertEqual(try secrets.load(ServiceMCPSecretProvider.reference), chatSecret)
  }

  func testQwenProfileChangesDoNotInterruptChatGPTAndSecretsStayIndependent() async throws {
    let root = temporaryRoot()
    let secrets = ServiceHostTestSecretStore()
    let chatSecret = String(repeating: "C", count: 43)
    let qwenSecret = String(repeating: "Q", count: 43)
    try secrets.store(Data(chatSecret.utf8), for: ServiceMCPSecretProvider.reference)
    try secrets.store(Data(qwenSecret.utf8), for: ServiceMCPSecretProvider.qwenStudioReference)
    let composition = try await makeComposition(root: root, secrets: secrets)
    defer {
      Task { await composition.shutdown() }
      try? FileManager.default.removeItem(at: root)
    }
    let endpoint = try await startLocalMCPOrSkip(composition)
    let chatClient = try await connectMCP(endpoint: endpoint.localURL, secret: chatSecret)
    defer { Task { await chatClient.disconnect() } }
    let initialChatTools = try await chatClient.listTools()
    XCTAssertEqual(initialChatTools.tools.count, 13)

    let pair = xpcClient(composition: composition)
    let xpc = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await xpc.invalidate() }
    }
    try await xpc.setMCPClientEnabled(clientID: MCPClientID.qwenStudio.rawValue, enabled: true)
    let qwenClient = try await connectMCP(endpoint: endpoint.localURL, secret: qwenSecret)
    defer { Task { await qwenClient.disconnect() } }
    let initialQwenTools = try await qwenClient.listTools()
    XCTAssertEqual(initialQwenTools.tools.count, 13)

    try await xpc.setMCPClientExposureMode(
      clientID: MCPClientID.qwenStudio.rawValue,
      mode: .full
    )
    let endpointAfterModeChange = await composition.endpoint()
    XCTAssertEqual(endpointAfterModeChange?.localURL, endpoint.localURL)
    let chatToolsAfterQwenModeChange = try await chatClient.listTools()
    XCTAssertEqual(chatToolsAfterQwenModeChange.tools.count, 13)
    let fullQwen = try await connectMCP(endpoint: endpoint.localURL, secret: qwenSecret)
    defer { Task { await fullQwen.disconnect() } }
    let fullTools = try await fullQwen.listTools()
    XCTAssertEqual(fullTools.tools.count, 26)
    XCTAssertTrue(fullTools.tools.contains { $0.name == MCPServiceToolName.submitTask.rawValue })
    XCTAssertTrue(
      fullTools.tools.contains { $0.name == MCPServiceToolName.directWriteProjectFile.rawValue }
    )
    XCTAssertTrue(
      fullTools.tools.contains { $0.name == MCPServiceToolName.runSkillAction.rawValue })

    try await xpc.rotateMCPClientCredential(clientID: MCPClientID.qwenStudio.rawValue)
    let chatToolsAfterQwenRotation = try await chatClient.listTools()
    XCTAssertEqual(chatToolsAfterQwenRotation.tools.count, 13)
    let storedChat = try secrets.load(ServiceMCPSecretProvider.reference)
    let storedQwen = try secrets.load(ServiceMCPSecretProvider.qwenStudioReference)
    XCTAssertEqual(String(data: storedChat, encoding: .utf8), chatSecret)
    XCTAssertNotEqual(String(data: storedQwen, encoding: .utf8), qwenSecret)
    XCTAssertNotEqual(storedChat, storedQwen)
    do {
      _ = try await connectMCP(endpoint: endpoint.localURL, secret: qwenSecret)
      XCTFail("The rotated Qwen credential must stop authenticating.")
    } catch {
      XCTAssertNotNil(error)
    }
    let rotatedQwenSecret = try XCTUnwrap(String(data: storedQwen, encoding: .utf8))
    let rotatedQwen = try await connectMCP(
      endpoint: endpoint.localURL,
      secret: rotatedQwenSecret
    )
    defer { Task { await rotatedQwen.disconnect() } }
    let rotatedQwenTools = try await rotatedQwen.listTools()
    XCTAssertEqual(rotatedQwenTools.tools.count, 26)

    let statuses = try await xpc.mcpClients()
    XCTAssertEqual(statuses.count, 2)
    XCTAssertFalse(String(describing: statuses).contains(chatSecret))
    XCTAssertFalse(String(describing: statuses).contains(qwenSecret))
    let exported = try await xpc.exportMCPClientConfiguration(
      clientID: MCPClientID.qwenStudio.rawValue
    )
    XCTAssertTrue(exported.contains(MCPHTTPConfiguration.tunnelAuthenticationHeader))
    XCTAssertFalse(exported.contains(chatSecret))
    let exportedObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any]
    )
    let servers = try XCTUnwrap(exportedObject["mcpServers"] as? [String: Any])
    let bridge = try XCTUnwrap(servers["Codex Bridge"] as? [String: Any])
    XCTAssertEqual(bridge["type"] as? String, "streamable-http")
    XCTAssertEqual(bridge["url"] as? String, endpoint.localURL.absoluteString)
    let headers = try XCTUnwrap(bridge["headers"] as? [String: String])
    XCTAssertEqual(headers[MCPHTTPConfiguration.tunnelAuthenticationHeader], rotatedQwenSecret)

    try await xpc.setMCPClientEnabled(
      clientID: MCPClientID.qwenStudio.rawValue,
      enabled: false
    )
    let chatToolsAfterQwenDisable = try await chatClient.listTools()
    XCTAssertEqual(chatToolsAfterQwenDisable.tools.count, 13)
  }

  func testCustomInstructionsInitializeAndRefreshChatGPTAndQwenSessions() async throws {
    let root = temporaryRoot()
    let secrets = ServiceHostTestSecretStore()
    let chatSecret = String(repeating: "C", count: 43)
    let qwenSecret = String(repeating: "Q", count: 43)
    try secrets.store(Data(chatSecret.utf8), for: ServiceMCPSecretProvider.reference)
    try secrets.store(Data(qwenSecret.utf8), for: ServiceMCPSecretProvider.qwenStudioReference)
    let composition = try await makeComposition(root: root, secrets: secrets)
    defer {
      Task { await composition.shutdown() }
      try? FileManager.default.removeItem(at: root)
    }
    let pair = xpcClient(composition: composition)
    let xpc = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await xpc.invalidate() }
    }

    try await xpc.setMCPClientEnabled(
      clientID: MCPClientID.qwenStudio.rawValue,
      enabled: true
    )
    let initialInstructions = "State the intended tool action first."
    try await xpc.setCustomInstructions(initialInstructions)
    let endpoint = try await startLocalMCPOrSkip(composition)
    let (chatClient, chatInitialization) = try await connectMCPWithInitialization(
      endpoint: endpoint.localURL,
      secret: chatSecret
    )
    let (qwenClient, qwenInitialization) = try await connectMCPWithInitialization(
      endpoint: endpoint.localURL,
      secret: qwenSecret
    )
    defer {
      Task {
        await chatClient.disconnect()
        await qwenClient.disconnect()
      }
    }
    XCTAssertTrue(chatInitialization.instructions?.contains(initialInstructions) == true)
    XCTAssertTrue(qwenInitialization.instructions?.contains(initialInstructions) == true)

    let connected = try await xpc.mcpClients()
    XCTAssertEqual(
      connected.first { $0.clientID == MCPClientID.chatGPT.rawValue }?.activeSessionCount,
      1
    )
    XCTAssertEqual(
      connected.first { $0.clientID == MCPClientID.qwenStudio.rawValue }?.activeSessionCount,
      1
    )

    let updatedInstructions = "Summarize the outcome after each tool call."
    try await xpc.setCustomInstructions(updatedInstructions)
    let refreshed = try await xpc.mcpClients()
    XCTAssertEqual(
      refreshed.first { $0.clientID == MCPClientID.chatGPT.rawValue }?.activeSessionCount,
      0
    )
    XCTAssertEqual(
      refreshed.first { $0.clientID == MCPClientID.qwenStudio.rawValue }?.activeSessionCount,
      0
    )

    let (newChatClient, newChatInitialization) = try await connectMCPWithInitialization(
      endpoint: endpoint.localURL,
      secret: chatSecret
    )
    let (newQwenClient, newQwenInitialization) = try await connectMCPWithInitialization(
      endpoint: endpoint.localURL,
      secret: qwenSecret
    )
    defer {
      Task {
        await newChatClient.disconnect()
        await newQwenClient.disconnect()
      }
    }
    XCTAssertTrue(newChatInitialization.instructions?.contains(updatedInstructions) == true)
    XCTAssertTrue(newQwenInitialization.instructions?.contains(updatedInstructions) == true)
  }

  func testRandomLocalPortPersistsAcrossServiceRestart() async throws {
    let root = temporaryRoot()
    let secrets = ServiceHostTestSecretStore()
    let first = try await makeComposition(root: root, secrets: secrets)
    let firstEndpoint = try await startLocalMCPOrSkip(first)
    await first.shutdown()

    let reopened = try await makeComposition(root: root, secrets: secrets)
    defer {
      Task { await reopened.shutdown() }
      try? FileManager.default.removeItem(at: root)
    }
    let reopenedEndpoint = try await startLocalMCPOrSkip(reopened)
    XCTAssertEqual(reopenedEndpoint.localURL, firstEndpoint.localURL)
    let storedPort = try await reopened.settings.localMCPPort()
    XCTAssertEqual(storedPort, firstEndpoint.port)
  }

  func testConfiguredOccupiedPortFailsWithoutDrifting() async throws {
    let occupied: OccupiedLoopbackPort
    do {
      occupied = try OccupiedLoopbackPort()
    } catch let error as POSIXError where error.code == .EPERM {
      throw XCTSkip("The execution sandbox forbids loopback socket binding.")
    }
    defer { occupied.close() }
    let root = temporaryRoot()
    let secrets = ServiceHostTestSecretStore()
    let composition = try await makeComposition(
      root: root,
      secrets: secrets,
      mcpPort: occupied.port
    )
    defer {
      Task { await composition.shutdown() }
      try? FileManager.default.removeItem(at: root)
    }

    do {
      _ = try await composition.startLocalMCP()
      XCTFail("An occupied fixed port must fail.")
    } catch {
      XCTAssertEqual(
        error as? ServiceLocalMCPError,
        .localPortUnavailable(occupied.port)
      )
      let endpoint = await composition.endpoint()
      let storedPort = try await composition.settings.localMCPPort()
      XCTAssertNil(endpoint)
      XCTAssertNil(storedPort)
    }
  }

  private func makeComposition(
    root: URL,
    secrets: ServiceHostTestSecretStore,
    mcpPort: Int = 0
  ) async throws -> ServiceComposition {
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    return try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.3.0",
        dataRootURL: root,
        executionAppServer: unavailable,
        supervisorAppServer: unavailable,
        catalogAppServer: unavailable,
        clientInfo: .bridge(version: "qwen-host-tests"),
        mcpPort: mcpPort
      ),
      secretStore: secrets
    )
  }

  private func startLocalMCPOrSkip(_ composition: ServiceComposition) async throws
    -> MCPBridgeEndpoint
  {
    do {
      return try await composition.startLocalMCP()
    } catch {
      guard String(describing: error).contains("Operation not permitted") else { throw error }
      throw XCTSkip("The execution sandbox forbids loopback socket binding.")
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "bridge-qwen-host-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func connectMCP(endpoint: URL, secret: String) async throws -> Client {
    let (client, _) = try await connectMCPWithInitialization(
      endpoint: endpoint,
      secret: secret
    )
    return client
  }

  private func connectMCPWithInitialization(
    endpoint: URL,
    secret: String
  ) async throws -> (Client, Initialize.Result) {
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
    let client = Client(name: "qwen-host-tests", version: "1", configuration: .strict)
    let initialization = try await client.connect(transport: transport)
    return (client, initialization)
  }
}

private final class OccupiedLoopbackPort {
  let port: Int
  private var descriptor: Int32

  init() throws {
    let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0, Darwin.listen(socketDescriptor, 1) == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard
      withUnsafeMutablePointer(
        to: &bound,
        {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(socketDescriptor, $0, &length)
          }
        }
      ) == 0
    else {
      Darwin.close(socketDescriptor)
      throw POSIXError(.EIO)
    }
    descriptor = socketDescriptor
    port = Int(UInt16(bigEndian: bound.sin_port))
  }

  func close() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit {
    close()
  }
}
