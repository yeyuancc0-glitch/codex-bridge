import BridgeCodexRPC
import BridgeCodexService
import BridgeDirectCommand
import BridgeDomain
import BridgeLegacyImport
import BridgeMCP
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import Security

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
  public let legacyImportReport: LegacyImportReport?

  private let configuration: ServiceCompositionConfiguration
  private let secretProvider: ServiceMCPSecretProvider
  private var mcpServer: MCPBridgeServer?
  private var mcpEndpoint: MCPBridgeEndpoint?
  private var exposureMode: MCPServiceExposureMode?
  private var tunnelBootstrapped = false
  private var isShutdown = false

  public static func make(
    configuration: ServiceCompositionConfiguration,
    secretStore: any SecretStore = KeychainSecretStore(),
    randomBytes: @escaping @Sendable (Int) throws -> Data = { count in
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw ServiceMCPSecretError.randomGenerationFailed
      }
      return Data(bytes)
    },
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
      ?? BundledServiceTunnelManagerFactory(
        appBundleURL: configuration.appBundleURL ?? URL(fileURLWithPath: "/"),
        runtimeDirectory: paths.tunnelRuntimeURL,
        secretStore: secretStore
      )
    let tunnel = ServiceTunnelController(
      settings: settings,
      runtimeStatus: runtimeStatus,
      secretStore: secretStore,
      factory: resolvedTunnelFactory
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
      legacyImportReport: legacyImport.report,
      secretProvider: ServiceMCPSecretProvider(
        store: secretStore,
        randomBytes: randomBytes
      )
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
    legacyImportReport: LegacyImportReport?,
    secretProvider: ServiceMCPSecretProvider
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
    self.legacyImportReport = legacyImportReport
    self.secretProvider = secretProvider
  }

  @discardableResult
  public func startLocalMCP() async throws -> MCPBridgeEndpoint {
    guard !isShutdown else { throw CancellationError() }
    let requestedMode = try await settings.exposureMode()
    let mode = Self.mcpExposureMode(requestedMode)
    if exposureMode == mode, let mcpEndpoint { return mcpEndpoint }
    await tunnel.pauseForMCPRestart()
    await stopMCP()
    let secret = try await secretProvider.secret()
    let server = MCPBridgeServer(
      appVersion: configuration.appVersion,
      service: application,
      exposureMode: mode,
      httpConfiguration: try MCPHTTPConfiguration(
        headerSecret: secret,
        port: configuration.mcpPort
      )
    )
    do {
      let endpoint = try await server.start()
      guard !isShutdown else {
        await server.stop()
        throw CancellationError()
      }
      mcpServer = server
      mcpEndpoint = endpoint
      exposureMode = mode
      await runtimeStatus.updateMCP(state: "ready")
      if tunnelBootstrapped {
        await tunnel.localMCPDidChange(
          endpoint.localURL,
          localMCPHeaderSecret: secret
        )
      } else {
        tunnelBootstrapped = true
        await tunnel.bootstrap(
          localMCPURL: endpoint.localURL,
          localMCPHeaderSecret: secret
        )
      }
      return endpoint
    } catch {
      await runtimeStatus.updateMCP(
        state: "failed",
        degradation: "Local MCP could not start."
      )
      throw error
    }
  }

  @discardableResult
  public func setExposureMode(_ mode: MCPServiceExposureMode) async throws
    -> MCPBridgeEndpoint
  {
    try await settings.setExposureMode(Self.serviceExposureMode(mode))
    exposureMode = nil
    return try await startLocalMCP()
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
    exposureMode = nil
    await server?.stop()
  }

  private static func importLegacyConfiguration(
    from rootURL: URL?,
    into store: SimpleServiceStore
  ) async -> LegacyConfigurationImportBootstrap {
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

  let report: LegacyImportReport?
  let degradations: [String]
}
