import BridgeCodexRPC
import BridgeCodexService
import BridgeDirectCommand
import BridgeDomain
import BridgeMCP
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

#if canImport(Darwin)
  import BridgeLegacyImport
  public typealias ServiceLegacyImportReport = LegacyImportReport
#else
  public struct ServiceLegacyImportReport: Sendable {}
#endif

public enum ServiceLocalMCPError: Error, Equatable, Sendable {
  case localPortUnavailable(Int)
  case endpointManagedByConfiguration
}

public struct ServiceMCPClientStatus: Equatable, Sendable {
  public let profile: ServiceMCPClientProfile
  public let activeSessionCount: Int
  public let lastConnectedAt: Date?

  public init(
    profile: ServiceMCPClientProfile,
    activeSessionCount: Int,
    lastConnectedAt: Date?
  ) {
    self.profile = profile
    self.activeSessionCount = activeSessionCount
    self.lastConnectedAt = lastConnectedAt
  }
}

public struct ServiceCompositionConfiguration: Sendable {
  public let appVersion: String
  public let dataRootURL: URL
  public let executionAppServer: AppServerConfiguration
  public let supervisorAppServer: AppServerConfiguration
  public let catalogAppServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let mcpPort: Int
  public let appBundleURL: URL?
  public let legacyDataRootURL: URL?

  public init(
    appVersion: String,
    dataRootURL: URL = ServiceDataPaths.defaultRoot(),
    executionAppServer: AppServerConfiguration = .codex(),
    supervisorAppServer: AppServerConfiguration = .codex(),
    catalogAppServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    mcpPort: Int = 0,
    appBundleURL: URL? = ServiceBundleLocator.currentAppBundleURL(),
    legacyDataRootURL: URL? = nil
  ) {
    precondition(!appVersion.isEmpty)
    precondition((0...65_535).contains(mcpPort))
    self.appVersion = appVersion
    self.dataRootURL = dataRootURL
    self.executionAppServer = executionAppServer
    self.supervisorAppServer = supervisorAppServer
    self.catalogAppServer = catalogAppServer
    self.clientInfo = clientInfo
    self.mcpPort = mcpPort
    self.appBundleURL = appBundleURL?.standardizedFileURL
    self.legacyDataRootURL = legacyDataRootURL?.standardizedFileURL
  }
}

public actor ServiceComposition {
  public let paths: ServiceDataPaths
  public let store: SimpleServiceStore
  public let projects: ServiceProjectService
  public let tasks: ServiceTaskManager
  public let settings: ServiceSettings
  public let execution: ExecutionManager
  public let supervisor: SupervisorManager
  public let coordinator: ServiceExecutionCoordinator
  public let catalog: ServiceCodexCatalog
  public let runtimeStatus: ServiceRuntimeStatus
  public let application: BridgeServiceApplication
  public let tunnel: ServiceTunnelController
  public let mcpClients: ServiceMCPClientRegistry
  public let legacyImportReport: ServiceLegacyImportReport?

  private let configuration: ServiceCompositionConfiguration
  private var mcpServer: MCPBridgeServer?
  private var mcpEndpoint: MCPBridgeEndpoint?
  private var tunnelBootstrapped = false
  private var isShutdown = false

  public static func make(
    configuration: ServiceCompositionConfiguration,
    secretStore: any SecretStore,
    randomBytes: (@Sendable (Int) throws -> Data)? = nil,
    tunnelFactory: (any ServiceTunnelManagerBuilding)? = nil
  ) async throws -> ServiceComposition {
    let paths = try ServiceDataPaths.prepare(at: configuration.dataRootURL)
    let store = try SimpleServiceStore(path: paths.databaseURL.path)
    let legacyImport = await Self.importLegacyConfiguration(
      from: configuration.legacyDataRootURL,
      into: store
    )
    _ = try await store.markIncompleteTasksUnknown(at: Date())
    let projects = ServiceProjectService(store: store)
    let tasks = ServiceTaskManager(store: store)
    let settings = ServiceSettings(store: store)
    let execution = ExecutionManager(
      configuration: ExecutionManagerConfiguration(
        appServer: configuration.executionAppServer,
        clientInfo: configuration.clientInfo
      )
    )
    let supervisor = SupervisorManager(
      configuration: SupervisorManagerConfiguration(
        appServer: configuration.supervisorAppServer,
        clientInfo: configuration.clientInfo,
        scratchRootURL: paths.supervisorScratchURL
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: tasks,
      projects: projects,
      execution: execution,
      supervisor: supervisor
    )
    let catalog = ServiceCodexCatalog(
      configuration: ServiceCodexCatalogConfiguration(
        appServer: configuration.catalogAppServer,
        clientInfo: configuration.clientInfo
      )
    )
    let runtimeStatus = ServiceRuntimeStatus(
      initial: ServiceRuntimeStatusSnapshot(
        mcpState: "stopped",
        tunnelState: "stopped",
        degradations: legacyImport.degradations
      )
    )
    let application = BridgeServiceApplication(
      appVersion: configuration.appVersion,
      projects: projects,
      tasks: tasks,
      settings: settings,
      coordinator: coordinator,
      catalog: catalog,
      runtimeStatus: runtimeStatus,
      directCommands: DirectCommandSessionManager(
        orphanPIDFileURL: paths.supervisorScratchURL.appending(path: "direct-command-pids.txt")
      )
    )
    let resolvedTunnelFactory =
      tunnelFactory
      ?? DefaultServiceTunnelManagerFactory.make(
        appBundleURL: configuration.appBundleURL,
        runtimeDirectory: paths.tunnelRuntimeURL,
        secretStore: secretStore
      )
    let tunnel = ServiceTunnelController(
      settings: settings,
      runtimeStatus: runtimeStatus,
      secretStore: secretStore,
      factory: resolvedTunnelFactory
    )
    let secretProvider: ServiceMCPSecretProvider
    if let randomBytes {
      secretProvider = ServiceMCPSecretProvider(
        store: secretStore,
        randomBytes: randomBytes
      )
    } else {
      secretProvider = ServiceMCPSecretProvider(store: secretStore)
    }
    let mcpClients = try await ServiceMCPClientRegistry.make(
      settings: settings,
      secrets: secretProvider
    )
    return ServiceComposition(
      configuration: configuration,
      paths: paths,
      store: store,
      projects: projects,
      tasks: tasks,
      settings: settings,
      execution: execution,
      supervisor: supervisor,
      coordinator: coordinator,
      catalog: catalog,
      runtimeStatus: runtimeStatus,
      application: application,
      tunnel: tunnel,
      mcpClients: mcpClients,
      legacyImportReport: legacyImport.report
    )
  }

  private init(
    configuration: ServiceCompositionConfiguration,
    paths: ServiceDataPaths,
    store: SimpleServiceStore,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    settings: ServiceSettings,
    execution: ExecutionManager,
    supervisor: SupervisorManager,
    coordinator: ServiceExecutionCoordinator,
    catalog: ServiceCodexCatalog,
    runtimeStatus: ServiceRuntimeStatus,
    application: BridgeServiceApplication,
    tunnel: ServiceTunnelController,
    mcpClients: ServiceMCPClientRegistry,
    legacyImportReport: ServiceLegacyImportReport?
  ) {
    self.configuration = configuration
    self.paths = paths
    self.store = store
    self.projects = projects
    self.tasks = tasks
    self.settings = settings
    self.execution = execution
    self.supervisor = supervisor
    self.coordinator = coordinator
    self.catalog = catalog
    self.runtimeStatus = runtimeStatus
    self.application = application
    self.tunnel = tunnel
    self.mcpClients = mcpClients
    self.legacyImportReport = legacyImportReport
  }

  @discardableResult
  public func startLocalMCP() async throws -> MCPBridgeEndpoint {
    guard !isShutdown else { throw CancellationError() }
    if let mcpEndpoint { return mcpEndpoint }
    await tunnel.pauseForMCPRestart()
    await stopMCP()
    let persistedPort = configuration.mcpPort == 0 ? try await settings.localMCPPort() : nil
    let requestedPort = configuration.mcpPort == 0 ? persistedPort ?? 0 : configuration.mcpPort
    let chatGPTSecret = try await mcpClients.chatGPTCredential()
    let server = MCPBridgeServer(
      appVersion: configuration.appVersion,
      service: application,
      exposureMode: { [mcpClients] clientID in
        await mcpClients.exposureMode(for: clientID)
      },
      httpConfiguration: try MCPHTTPConfiguration(
        clientAuthenticator: mcpClients.authenticator,
        port: requestedPort
      ),
      clientAdmission: mcpClients.admission
    )
    do {
      let endpoint = try await server.start()
      guard !isShutdown else {
        await server.stop()
        throw CancellationError()
      }
      if configuration.mcpPort == 0, persistedPort == nil {
        try await settings.setLocalMCPPort(endpoint.port)
      }
      mcpServer = server
      mcpEndpoint = endpoint
      await runtimeStatus.updateMCP(state: "ready")
      if tunnelBootstrapped {
        await tunnel.localMCPDidChange(
          endpoint.localURL,
          localMCPHeaderSecret: chatGPTSecret
        )
      } else {
        tunnelBootstrapped = true
        await tunnel.bootstrap(
          localMCPURL: endpoint.localURL,
          localMCPHeaderSecret: chatGPTSecret
        )
      }
      return endpoint
    } catch {
      if mcpServer !== server {
        await server.stop()
      }
      let state = requestedPort == 0 ? "failed" : "local_port_unavailable"
      await runtimeStatus.updateMCP(
        state: state,
        degradation: requestedPort == 0
          ? "Local MCP could not start."
          : "Local MCP port \(requestedPort) is unavailable."
      )
      if requestedPort != 0 {
        throw ServiceLocalMCPError.localPortUnavailable(requestedPort)
      }
      throw error
    }
  }

  @discardableResult
  public func setExposureMode(_ mode: MCPServiceExposureMode) async throws
    -> MCPBridgeEndpoint
  {
    try await settings.setExposureMode(Self.serviceExposureMode(mode))
    await mcpServer?.terminateSessions(for: .chatGPT)
    return try await startLocalMCP()
  }

  public func mcpClientStatuses() async throws -> [ServiceMCPClientStatus] {
    let profiles = try await mcpClients.profiles()
    var statuses: [ServiceMCPClientStatus] = []
    statuses.reserveCapacity(profiles.count)
    for profile in profiles {
      statuses.append(
        ServiceMCPClientStatus(
          profile: profile,
          activeSessionCount: await mcpServer?.activeSessionCount(for: profile.clientID) ?? 0,
          lastConnectedAt: mcpClients.authenticator.lastAuthenticationDate(
            for: profile.clientID
          )
        )
      )
    }
    return statuses
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    do {
      try await mcpClients.setQwenStudioEnabled(enabled)
    } catch {
      await mcpServer?.terminateSessions(for: .qwenStudio)
      throw error
    }
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await mcpClients.setQwenStudioExposureMode(mode)
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func rotateQwenStudioCredential() async throws {
    do {
      try await mcpClients.rotateQwenStudioCredential()
    } catch {
      await mcpServer?.terminateSessions(for: .qwenStudio)
      throw error
    }
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func exportQwenStudioConfiguration() async throws -> String {
    let endpoint = try await startLocalMCP()
    let credential = try await mcpClients.qwenStudioCredential()
    let configuration: [String: Any] = [
      "mcpServers": [
        "Codex Bridge": [
          "type": "streamable-http",
          "url": endpoint.localURL.absoluteString,
          "headers": [MCPHTTPConfiguration.tunnelAuthenticationHeader: credential],
        ]
      ]
    ]
    let data = try JSONSerialization.data(
      withJSONObject: configuration,
      options: [.prettyPrinted, .sortedKeys]
    )
    guard let value = String(data: data, encoding: .utf8) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    return value
  }

  public func rotateLocalMCPEndpoint() async throws -> MCPBridgeEndpoint {
    guard configuration.mcpPort == 0 else {
      throw ServiceLocalMCPError.endpointManagedByConfiguration
    }
    let previousPort: Int?
    if let activePort = mcpEndpoint?.port {
      previousPort = activePort
    } else {
      previousPort = try await settings.localMCPPort()
    }
    await tunnel.pauseForMCPRestart()
    await stopMCP()
    try await settings.setLocalMCPPort(nil)
    do {
      for _ in 0..<4 {
        let endpoint = try await startLocalMCP()
        guard endpoint.port == previousPort else { return endpoint }
        await tunnel.pauseForMCPRestart()
        await stopMCP()
        try await settings.setLocalMCPPort(nil)
      }
      throw ServiceLocalMCPError.localPortUnavailable(previousPort ?? 0)
    } catch {
      if let previousPort {
        try? await settings.setLocalMCPPort(previousPort)
        _ = try? await startLocalMCP()
      }
      throw error
    }
  }

  public func configureTunnel(
    tunnelID: String,
    runtimeKey: String
  ) async throws -> ServiceTunnelSnapshot {
    try await tunnel.configure(tunnelID: tunnelID, runtimeKey: runtimeKey)
  }

  public func connectTunnel() async throws -> ServiceTunnelSnapshot {
    try await tunnel.connect()
  }

  public func disconnectTunnel() async throws {
    try await tunnel.disconnect()
  }

  public func clearTunnelConfiguration() async throws {
    try await tunnel.clearConfiguration()
  }

  public func tunnelStatus() async -> ServiceTunnelSnapshot {
    await tunnel.status()
  }

  public func endpoint() -> MCPBridgeEndpoint? {
    mcpEndpoint
  }

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    await tunnel.shutdown()
    await stopMCP()
    await coordinator.shutdown()
    await application.shutdownDirectOperations()
    await runtimeStatus.updateMCP(state: "stopped")
  }

  private func stopMCP() async {
    let server = mcpServer
    mcpServer = nil
    mcpEndpoint = nil
    await server?.stop()
  }

  private static func importLegacyConfiguration(
    from rootURL: URL?,
    into store: SimpleServiceStore
  ) async -> LegacyConfigurationImportBootstrap {
    #if canImport(Darwin)
      guard let rootURL else { return .disabled }
      do {
        let report = try await LegacyConfigurationImporter(
          legacyRootURL: rootURL,
          store: store
        ).importIfNeeded()
        return LegacyConfigurationImportBootstrap(
          report: report,
          degradations: []
        )
      } catch {
        return .failed
      }
    #else
      _ = (rootURL, store)
      return .disabled
    #endif
  }

  private static func mcpExposureMode(
    _ mode: ServiceMCPExposureMode
  ) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func serviceExposureMode(
    _ mode: MCPServiceExposureMode
  ) -> ServiceMCPExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }
}

private struct LegacyConfigurationImportBootstrap: Sendable {
  static let disabled = LegacyConfigurationImportBootstrap(
    report: nil,
    degradations: []
  )
  static let failed = LegacyConfigurationImportBootstrap(
    report: nil,
    degradations: [
      "Migration: Legacy configuration import failed; existing Service data was left unchanged."
    ]
  )

  let report: ServiceLegacyImportReport?
  let degradations: [String]
}
