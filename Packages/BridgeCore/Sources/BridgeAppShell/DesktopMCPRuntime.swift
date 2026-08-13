import BridgeApplication
import BridgeMCP
import Foundation
import MCP

enum DesktopMCPAuthentication: Equatable, Sendable {
  case path(secret: String)
  case header(secret: String)
}

enum DesktopMCPRuntimeError: LocalizedError, Equatable, Sendable {
  case invalidToolCatalog

  var errorDescription: String? {
    switch self {
    case .invalidToolCatalog:
      "本地 MCP 未返回预期的受限工具目录。"
    }
  }
}

actor DesktopMCPRuntime {
  private let application: BridgeApplicationService
  private let status: BridgeStatusStore
  private var server: MCPBridgeServer?
  private var endpoint: MCPBridgeEndpoint?
  private var authentication: DesktopMCPAuthentication?

  init(application: BridgeApplicationService, status: BridgeStatusStore) {
    self.application = application
    self.status = status
  }

  func start(authentication requested: DesktopMCPAuthentication) async throws -> URL {
    if requested == authentication, let endpoint { return endpoint.localURL }
    if let server { await server.stop() }
    let configuration: MCPHTTPConfiguration
    switch requested {
    case .path(let secret):
      configuration = try MCPHTTPConfiguration(pathSecret: secret)
    case .header(let secret):
      configuration = try MCPHTTPConfiguration(headerSecret: secret)
    }
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: application,
      projectOperations: application,
      httpConfiguration: configuration
    )
    let endpoint = try await server.start()
    self.server = server
    self.endpoint = endpoint
    authentication = requested
    await status.update(Self.statusSnapshot(mcpState: "ready"))
    return endpoint.localURL
  }

  func testConnection() async throws {
    guard let endpoint, let authentication else {
      throw DesktopBackendError.connectionNotConfigured
    }
    let header: (String, String)? =
      switch authentication {
      case .path: nil
      case .header(let secret): (MCPHTTPConfiguration.tunnelAuthenticationHeader, secret)
      }
    try await Self.validate(endpoint: endpoint.localURL, header: header)
  }

  static func validate(
    endpoint: URL,
    header: (String, String)? = nil
  ) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let transport = HTTPClientTransport(
      endpoint: endpoint,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1,
      requestModifier: { request in
        guard let header else { return request }
        var request = request
        request.setValue(header.1, forHTTPHeaderField: header.0)
        return request
      }
    )
    try await validate(transport: transport)
  }

  static func validate(transport: any Transport) async throws {
    let client = Client(
      name: "codex-bridge-onboarding",
      version: "0.1.0",
      configuration: .strict
    )
    do {
      let initialized = try await client.connect(transport: transport)
      guard initialized.serverInfo.name == "codex-bridge" else {
        throw DesktopMCPRuntimeError.invalidToolCatalog
      }
      let tools = try await client.listTools()
      let expected = MCPToolCatalog(includeProjectTools: true).definitions.map(\.name)
      guard tools.tools.map(\.name) == expected else {
        throw DesktopMCPRuntimeError.invalidToolCatalog
      }
      await client.disconnect()
    } catch {
      await client.disconnect()
      throw error
    }
  }

  func stop() async {
    let server = server
    self.server = nil
    endpoint = nil
    authentication = nil
    await server?.stop()
    await status.update(Self.statusSnapshot(mcpState: "stopped"))
  }

  private static func statusSnapshot(mcpState: String) -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "0.1.0",
      mcpState: mcpState,
      tunnelState: "stopped",
      executionState: "idle",
      supervisorState: "idle",
      degradations: ["Remote task submission tools are not enabled."],
      pendingApprovalCount: 0
    )
  }
}

extension DesktopMCPRuntime: DesktopMCPServing {}
