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
  let projectMutationGate: TaskProjectMutationGate
  let taskRuntime: IsolatedCodexTaskRuntime
  let coordinator: TaskCoordinator
  let application: BridgeApplicationService
  let taskEvidence: DesktopTaskEvidenceProjection
  let pipelineArtifacts: PipelineArtifactStore
  let supervisionLedger: DurableSupervisionLedger
  let retentionCoordinator: DesktopTaskRetentionCoordinator
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
    let projectMutationGate = TaskProjectMutationGate()
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
      pipeline: pipelineRelay,
      projectMutationGate: projectMutationGate
    )
    let pipelineArtifacts = try PipelineArtifactStore(path: paths.eventStoreURL.path)
    let supervisionLedger = try DurableSupervisionLedger(
      path: paths.supervisionLedgerURL.path
    )
    let pipelineFinalizer = PipelineFinalizer(
      artifacts: pipelineArtifacts,
      coordinator: coordinator,
      reports: repository
    )
    let supervisorAuthentication = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        clientInfo: .bridge(version: "0.1.0")
      ),
      openAuthenticationURL: { url in
        await MainActor.run { system.open(url) }
      }
    )
    let supervisorRuntime = CodexSupervisorRuntime(
      configuration: CodexSupervisorRuntimeConfiguration(
        clientInfo: .bridge(version: "0.1.0"),
        evidenceOnlyHomeURL: paths.supervisorHomeURL,
        authenticationProvisioner: supervisorAuthentication
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
    let preflightStore = try PipelinePreflightStore(path: paths.pipelinePreflightURL.path)
    let pipelineOrchestrator = TaskPipelineOrchestrator(
      preflight: preflightStore,
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
      },
      supervision: supervisionLedger
    )
    let retentionCoordinator = DesktopTaskRetentionCoordinator(
      eventStore: eventStore,
      coordinator: coordinator,
      pipelineArtifacts: pipelineArtifacts,
      supervision: supervisionLedger,
      patches: patchStore,
      reports: repository,
      preflight: preflightStore,
      authorizations: verificationStore
    )
    try await pipelineRelay.install(pipelineOrchestrator)
    _ = try await pipelineFinalizer.recoverPendingFinalizations()
    _ = try await pipelineOrchestrator.recoverPendingPreflights()
    _ = try await coordinator.recoverIncompleteTasks()
    _ = try await retentionCoordinator.run()
    let catalog: any CodexCatalogQuerying =
      suppliedCatalog
      ?? IsolatedCodexCatalogService(
        configuration: IsolatedCodexCatalogConfiguration(
          clientInfo: .bridge(version: "0.1.0")
        )
      )
    let status = BridgeStatusStore(
      initial: DesktopSupervisorAvailability.current.status(
        mcpState: "stopped",
        tunnelState: "stopped"
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
      coordinator: coordinator,
      supervision: supervisionLedger
    )
    let mcpRuntime = DesktopMCPRuntime(
      application: application,
      status: status,
      availability: DesktopSupervisorAvailability.current
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
      admissionGate: admissionGate,
      availability: DesktopSupervisorAvailability.current
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
      projectMutationGate: projectMutationGate,
      taskRuntime: taskRuntime,
      coordinator: coordinator,
      application: application,
      taskEvidence: taskEvidence,
      pipelineArtifacts: pipelineArtifacts,
      supervisionLedger: supervisionLedger,
      retentionCoordinator: retentionCoordinator,
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
  struct Snapshot: Equatable, Sendable {
    let isAvailable: Bool

    var state: String { isAvailable ? "ready" : "unavailable" }

    var degradation: String? {
      isAvailable
        ? nil
        : "Supervisor is disabled until isolated Codex authentication and a credentialed boundary test pass."
    }

    func status(
      mcpState: String,
      tunnelState: String,
      additionalDegradations: [String] = []
    ) -> BridgeStatusSnapshot {
      BridgeStatusSnapshot(
        appVersion: "0.1.0",
        mcpState: mcpState,
        tunnelState: tunnelState,
        executionState: "idle",
        supervisorState: state,
        degradations: (degradation.map { [$0] } ?? []) + additionalDegradations,
        pendingApprovalCount: 0
      )
    }
  }

  static let current = Snapshot(isAvailable: false)
  static var productionReviewAvailable: Bool { current.isAvailable }
}
