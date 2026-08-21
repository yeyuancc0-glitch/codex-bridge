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
  private let taskOperations: DesktopMCPTaskOperations
  private let status: BridgeStatusStore
  private let availability: DesktopSupervisorAvailability.Snapshot
  private var server: MCPBridgeServer?
  private var endpoint: MCPBridgeEndpoint?
  private var authentication: DesktopMCPAuthentication?
  private var lifecycleGeneration: UInt64 = 0
  private var isShutdown = false
  private var mutationActive = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    application: BridgeApplicationService,
    status: BridgeStatusStore,
    availability: DesktopSupervisorAvailability.Snapshot = DesktopSupervisorAvailability.current
  ) {
    self.application = application
    taskOperations = DesktopMCPTaskOperations(
      application: application,
      supervisorAvailable: availability.isAvailable
    )
    self.status = status
    self.availability = availability
  }

  func start(authentication requested: DesktopMCPAuthentication) async throws -> URL {
    await beginMutation()
    defer { endMutation() }
    guard !isShutdown else { throw DesktopBackendError.operationFailed }
    if requested == authentication, let endpoint { return endpoint.localURL }
    lifecycleGeneration &+= 1
    let generation = lifecycleGeneration
    if let server { await server.stop() }
    let configuration: MCPHTTPConfiguration
    switch requested {
    case .path(let secret):
      await taskOperations.configure(requiresHealthyRemote: false)
      configuration = try MCPHTTPConfiguration(pathSecret: secret)
    case .header(let secret):
      await taskOperations.configure(requiresHealthyRemote: true)
      configuration = try MCPHTTPConfiguration(headerSecret: secret)
    }
    let server = MCPBridgeServer(
      appVersion: "0.1.0",
      queries: application,
      taskOperations: taskOperations,
      projectOperations: application,
      httpConfiguration: configuration
    )
    let endpoint = try await server.start()
    guard !isShutdown, generation == lifecycleGeneration else {
      await server.stop()
      throw CancellationError()
    }
    self.server = server
    self.endpoint = endpoint
    authentication = requested
    await status.update(availability.status(mcpState: "ready", tunnelState: "stopped"))
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
      let expected = MCPToolCatalog(
        includeTaskTools: true,
        includeProjectTools: true
      ).definitions.map(\.name)
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
    await beginMutation()
    defer { endMutation() }
    lifecycleGeneration &+= 1
    await stopCurrentServer()
  }

  func shutdown() async {
    isShutdown = true
    await beginMutation()
    defer { endMutation() }
    lifecycleGeneration &+= 1
    await stopCurrentServer()
  }

  private func stopCurrentServer() async {
    let server = server
    self.server = nil
    endpoint = nil
    authentication = nil
    await server?.stop()
    await status.update(availability.status(mcpState: "stopped", tunnelState: "stopped"))
  }

  private func beginMutation() async {
    guard mutationActive else {
      mutationActive = true
      return
    }
    await withCheckedContinuation { mutationWaiters.append($0) }
  }

  private func endMutation() {
    guard let next = mutationWaiters.first else {
      mutationActive = false
      return
    }
    mutationWaiters.removeFirst()
    next.resume()
  }

  func setRemoteTaskAdmissionCheck(
    _ check: (@Sendable () async -> Bool)?
  ) async {
    await taskOperations.setRemoteAdmissionCheck(check)
  }

  func setRemoteTaskAdmissionLeaseCheck(
    _ check: (@Sendable () async -> DesktopRemoteAdmissionLease?)?
  ) async {
    await taskOperations.setRemoteAdmissionLeaseCheck(check)
  }

}

extension DesktopMCPRuntime: DesktopMCPServing {}
