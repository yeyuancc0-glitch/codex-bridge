import BridgeApplication
import BridgeCodexRPC
import BridgeCoordinator
import BridgeDomain
import BridgeMCP
import BridgePersistence
import BridgePipeline
import BridgeProjects
import BridgeRepositories
import BridgeRuntime
import BridgeSecurity
import Foundation

struct DesktopComposition: Sendable {
  let eventStore: EventStore
  let repository: ApplicationRepository
  let registry: ProjectRegistry
  let taskRuntime: IsolatedCodexTaskRuntime
  let coordinator: TaskCoordinator
  let pipelineArtifacts: PipelineArtifactStore
  let pipelineFinalizer: PipelineFinalizer
  let connectionRuntime: DesktopConnectionRuntime

  static func make(
    dataDirectoryURL: URL,
    system: any DesktopSystemServing,
    secretStore: any SecretStore = KeychainSecretStore(),
    bundleURL: URL = Bundle.main.bundleURL
  ) async throws -> DesktopComposition {
    let paths = try DesktopDataStore.prepare(at: dataDirectoryURL)
    let eventStore = try EventStore(path: paths.eventStoreURL.path)
    let repository = try ApplicationRepository(path: paths.applicationRepositoryURL.path)
    let registry = ProjectRegistry(repository: repository)
    let taskRuntime = IsolatedCodexTaskRuntime(
      registry: registry,
      locations: ClosureRuntimeProjectLocationResolver { submission in
        guard let project = try await repository.project(id: submission.projectID) else {
          throw ProjectRegistryError.unknownProject
        }
        return RuntimeProjectLocation(
          workingDirectoryURL: URL(fileURLWithPath: project.primaryRoot.canonicalPath),
          repositoryRootURL: URL(fileURLWithPath: project.repositoryRoot.canonicalPath)
        )
      },
      configuration: IsolatedCodexTaskRuntimeConfiguration(
        clientInfo: .bridge(version: "0.1.0")
      )
    )
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: DefaultTaskAdmissionPolicy(registry: registry),
      runtime: taskRuntime
    )
    let pipelineArtifacts = try PipelineArtifactStore(path: paths.eventStoreURL.path)
    let pipelineFinalizer = PipelineFinalizer(
      artifacts: pipelineArtifacts,
      coordinator: coordinator,
      reports: repository
    )
    _ = try await pipelineFinalizer.recoverPendingFinalizations()
    _ = try await coordinator.recoverIncompleteTasks()
    let catalog = IsolatedCodexCatalogService(
      configuration: IsolatedCodexCatalogConfiguration(
        clientInfo: .bridge(version: "0.1.0")
      )
    )
    let status = BridgeStatusStore(
      initial: BridgeStatusSnapshot(
        appVersion: "0.1.0",
        mcpState: "stopped",
        tunnelState: "stopped",
        executionState: "unavailable",
        supervisorState: "unavailable",
        degradations: ["Task execution pipeline is not connected."],
        pendingApprovalCount: 0
      )
    )
    let application = BridgeApplicationService(
      coordinator: coordinator,
      eventStore: eventStore,
      projectRepository: repository,
      reportStore: repository,
      catalog: catalog,
      status: status,
      openCodexURL: { url in await system.open(url) }
    )
    let mcpRuntime = DesktopMCPRuntime(application: application, status: status)
    let connectionRuntime = DesktopConnectionRuntime(
      mcp: mcpRuntime,
      tunnelFactory: BundledDesktopTunnelManagerFactory(
        bundleURL: bundleURL,
        dataDirectoryURL: dataDirectoryURL,
        secretStore: secretStore
      ),
      status: status
    )
    return DesktopComposition(
      eventStore: eventStore,
      repository: repository,
      registry: registry,
      taskRuntime: taskRuntime,
      coordinator: coordinator,
      pipelineArtifacts: pipelineArtifacts,
      pipelineFinalizer: pipelineFinalizer,
      connectionRuntime: connectionRuntime
    )
  }

  func shutdown() async {
    await connectionRuntime.stop()
    await taskRuntime.shutdown()
  }
}
