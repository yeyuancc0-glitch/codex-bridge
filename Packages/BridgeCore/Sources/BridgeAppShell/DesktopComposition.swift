import BridgeApplication
import BridgeCodexRPC
import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgeMCP
import BridgePersistence
import BridgePipeline
import BridgeProjects
import BridgeReporting
import BridgeRepositories
import BridgeRuntime
import BridgeSecurity
import BridgeSupervisor
import BridgeVerification
import Foundation

struct DesktopComposition: Sendable {
  let instanceLease: DesktopApplicationInstanceLease
  let eventStore: EventStore
  let repository: ApplicationRepository
  let registry: ProjectRegistry
  let taskRuntime: IsolatedCodexTaskRuntime
  let coordinator: TaskCoordinator
  let application: BridgeApplicationService
  let taskEvidence: DesktopTaskEvidenceProjection
  let pipelineArtifacts: PipelineArtifactStore
  let pipelineFinalizer: PipelineFinalizer
  let pipelineOrchestrator: TaskPipelineOrchestrator
  let supervisorRuntime: CodexSupervisorRuntime
  let verificationAuthorization: DesktopVerificationAuthorizationService
  let mcpRuntime: DesktopMCPRuntime
  let connectionRuntime: DesktopConnectionRuntime
  let taskLifecycle: DesktopTaskLifecycleService
  let lifecycleCoordinator: DesktopTaskLifecycleCoordinator

  static func make(
    dataDirectoryURL: URL,
    system: any DesktopSystemServing,
    secretStore: any SecretStore = KeychainSecretStore(),
    bundleURL: URL = Bundle.main.bundleURL,
    catalog suppliedCatalog: (any CodexCatalogQuerying)? = nil
  ) async throws -> DesktopComposition {
    let paths = try DesktopDataStore.prepare(at: dataDirectoryURL)
    let instanceLease = try DesktopApplicationInstanceLease(directoryURL: paths.directoryURL)
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
    let pipelineRelay = DeferredTaskPipelineLifecycle()
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: DefaultTaskAdmissionPolicy(registry: registry),
      runtime: taskRuntime,
      pipeline: pipelineRelay
    )
    let pipelineArtifacts = try PipelineArtifactStore(path: paths.eventStoreURL.path)
    let pipelineFinalizer = PipelineFinalizer(
      artifacts: pipelineArtifacts,
      coordinator: coordinator,
      reports: repository
    )
    let supervisorRuntime = CodexSupervisorRuntime(
      configuration: CodexSupervisorRuntimeConfiguration(
        clientInfo: .bridge(version: "0.1.0")
      )
    )
    let verificationStore = try VerificationAuthorizationStore(
      path: paths.verificationAuthorizationURL.path
    )
    let verificationBroker = DesktopVerificationAuthorizationBroker(store: verificationStore)
    let verificationAuthorization = DesktopVerificationAuthorizationService(
      coordinator: coordinator,
      repository: repository,
      broker: verificationBroker
    )
    let patchStore = try GitPatchStore(persistentDirectory: paths.gitPatchDirectoryURL)
    let pipelineOrchestrator = TaskPipelineOrchestrator(
      preflight: try PipelinePreflightStore(path: paths.pipelinePreflightURL.path),
      artifacts: pipelineArtifacts,
      finalizer: pipelineFinalizer,
      coordinator: coordinator,
      projects: ClosureTaskPipelineProjectProvider { id in
        try await repository.project(id: id)
      },
      git: GitEvidenceCollector(
        rootAuthorizer: DesktopGitProjectRootAuthorizer(repository: repository),
        patchStore: patchStore
      ),
      verification: DesktopPipelineVerificationRunner(authorizations: verificationBroker),
      supervisor: supervisorRuntime,
      policy: ClosureTaskPipelinePolicyEvaluator { context in
        let verification = context.verification.map(\.reportingEvidence)
        let blockers = verification.filter { $0.required && $0.status == .failed }
          .map { "Required verification failed: \($0.name)" }
        let warnings = verification.filter { $0.status == .unavailable }
          .map { "Verification unavailable: \($0.name)" }
        return PolicyEvidence(
          evaluationCompleted: true,
          unresolvedBlockers: blockers,
          warnings: warnings
        )
      }
    )
    try await pipelineRelay.install(pipelineOrchestrator)
    _ = try await pipelineFinalizer.recoverPendingFinalizations()
    _ = try await pipelineOrchestrator.recoverPendingPreflights()
    _ = try await coordinator.recoverIncompleteTasks()
    let catalog: any CodexCatalogQuerying =
      suppliedCatalog
      ?? IsolatedCodexCatalogService(
        configuration: IsolatedCodexCatalogConfiguration(
          clientInfo: .bridge(version: "0.1.0")
        )
      )
    let status = BridgeStatusStore(
      initial: BridgeStatusSnapshot(
        appVersion: "0.1.0",
        mcpState: "stopped",
        tunnelState: "stopped",
        executionState: "idle",
        supervisorState: "unavailable",
        degradations: [DesktopSupervisorAvailability.degradation],
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
      artifacts: DesktopTaskArtifactQueries(
        artifacts: pipelineArtifacts,
        patches: patchStore
      ),
      openCodexURL: { url in await system.open(url) }
    )
    let taskEvidence = DesktopTaskEvidenceProjection(
      artifacts: pipelineArtifacts,
      patches: patchStore,
      reports: repository,
      coordinator: coordinator
    )
    let mcpRuntime = DesktopMCPRuntime(
      application: application,
      status: status,
      supervisorAvailable: DesktopSupervisorAvailability.productionReviewAvailable
    )
    let admissionGate = DesktopRemoteAdmissionGate()
    let connectionRuntime = DesktopConnectionRuntime(
      mcp: mcpRuntime,
      tunnelFactory: BundledDesktopTunnelManagerFactory(
        bundleURL: bundleURL,
        dataDirectoryURL: dataDirectoryURL,
        secretStore: secretStore
      ),
      status: status,
      admissionGate: admissionGate
    )
    await mcpRuntime.setRemoteTaskAdmissionLeaseCheck { [weak connectionRuntime] in
      await connectionRuntime?.acquireRemoteSubmissionLease()
    }
    let lifecyclePreferences = try await eventStore.lifecyclePreferences()
    let lifecycleOwner = UUID().uuidString.lowercased()
    let notificationLedger = DesktopTaskNotificationLedger(
      store: eventStore,
      ownerInstanceID: lifecycleOwner
    )
    let powerSource = await MainActor.run {
      WorkspaceDesktopPowerEventSource {
        _ = admissionGate.closeForSleep()
      }
    }
    let taskLifecycle = DesktopTaskLifecycleService(
      notifications: UserNotificationDesktopTaskNotifier(),
      notificationStore: notificationLedger,
      idleSleep: ProcessInfoDesktopIdleSleepPreventer(),
      powerSource: powerSource,
      notificationDeliveryEnabled: lifecyclePreferences.notificationsEnabled,
      idleSleepPreventionEnabled: lifecyclePreferences.idleSleepEnabled
    )
    let lifecycleCoordinator = DesktopTaskLifecycleCoordinator(
      eventStore: eventStore,
      coordinator: coordinator,
      service: taskLifecycle,
      connection: connectionRuntime,
      ownerInstanceID: lifecycleOwner
    )
    do {
      try await lifecycleCoordinator.start()
    } catch {
      await lifecycleCoordinator.shutdown()
      throw error
    }
    return DesktopComposition(
      instanceLease: instanceLease,
      eventStore: eventStore,
      repository: repository,
      registry: registry,
      taskRuntime: taskRuntime,
      coordinator: coordinator,
      application: application,
      taskEvidence: taskEvidence,
      pipelineArtifacts: pipelineArtifacts,
      pipelineFinalizer: pipelineFinalizer,
      pipelineOrchestrator: pipelineOrchestrator,
      supervisorRuntime: supervisorRuntime,
      verificationAuthorization: verificationAuthorization,
      mcpRuntime: mcpRuntime,
      connectionRuntime: connectionRuntime,
      taskLifecycle: taskLifecycle,
      lifecycleCoordinator: lifecycleCoordinator
    )
  }

  func shutdown() async {
    await mcpRuntime.shutdown()
    await lifecycleCoordinator.shutdown()
    await connectionRuntime.shutdown()
    await supervisorRuntime.shutdown()
    await taskRuntime.shutdown()
    instanceLease.release()
  }
}

enum DesktopSupervisorAvailability {
  static let productionReviewAvailable = false
  static let degradation =
    "Luna supervision is disabled because evidence-only process isolation is unavailable."
}
