import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
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

  public init(
    appVersion: String,
    dataRootURL: URL = ServiceDataPaths.defaultRoot(),
    executionAppServer: AppServerConfiguration = .codex(),
    supervisorAppServer: AppServerConfiguration = .codex(),
    catalogAppServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    mcpPort: Int = 0
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

  private let configuration: ServiceCompositionConfiguration
  private let secretProvider: ServiceMCPSecretProvider
  private var mcpServer: MCPBridgeServer?
  private var mcpEndpoint: MCPBridgeEndpoint?
  private var exposureMode: MCPServiceExposureMode?
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
    }
  ) async throws -> ServiceComposition {
    let paths = try ServiceDataPaths.prepare(at: configuration.dataRootURL)
    let store = try SimpleServiceStore(path: paths.databaseURL.path)
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
        tunnelState: "stopped"
      )
    )
    let application = BridgeServiceApplication(
      appVersion: configuration.appVersion,
      projects: projects,
      tasks: tasks,
      settings: settings,
      coordinator: coordinator,
      catalog: catalog,
      runtimeStatus: runtimeStatus
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
    self.secretProvider = secretProvider
  }

  @discardableResult
  public func startLocalMCP() async throws -> MCPBridgeEndpoint {
    guard !isShutdown else { throw CancellationError() }
    let requestedMode = try await settings.exposureMode()
    let mode = Self.mcpExposureMode(requestedMode)
    if exposureMode == mode, let mcpEndpoint { return mcpEndpoint }
    await stopMCP()
    let secret = try await secretProvider.secret()
    let server = MCPBridgeServer(
      appVersion: configuration.appVersion,
      service: application,
      exposureMode: mode,
      httpConfiguration: try MCPHTTPConfiguration(
        pathSecret: secret,
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
      await runtimeStatus.update(
        ServiceRuntimeStatusSnapshot(
          mcpState: "ready",
          tunnelState: "stopped"
        )
      )
      return endpoint
    } catch {
      await runtimeStatus.update(
        ServiceRuntimeStatusSnapshot(
          mcpState: "failed",
          tunnelState: "stopped",
          degradations: ["Local MCP could not start."]
        )
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

  public func endpoint() -> MCPBridgeEndpoint? {
    mcpEndpoint
  }

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    await stopMCP()
    await coordinator.shutdown()
    await runtimeStatus.update(
      ServiceRuntimeStatusSnapshot(
        mcpState: "stopped",
        tunnelState: "stopped"
      )
    )
  }

  private func stopMCP() async {
    let server = mcpServer
    mcpServer = nil
    mcpEndpoint = nil
    exposureMode = nil
    await server?.stop()
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
