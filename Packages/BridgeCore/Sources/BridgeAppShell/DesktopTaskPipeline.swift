import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePipeline
import BridgeProjects
import BridgeRepositories
import BridgeSecurity
import BridgeVerification
import Foundation

struct DesktopGitProjectRootAuthorizer: GitProjectRootAuthorizing {
  let repository: ApplicationRepository

  func authorizedCanonicalGitRoot(for projectIdentifier: String) async throws -> URL {
    guard
      let project = try await repository.project(id: ProjectID(rawValue: projectIdentifier))
    else { throw ProjectRegistryError.unknownProject }
    try project.repositoryRoot.validateCurrentIdentity()
    return URL(fileURLWithPath: project.repositoryRoot.canonicalPath, isDirectory: true)
  }
}

struct DesktopPipelineVerificationRunner: TaskPipelineVerificationRunning {
  let authorizations: DesktopVerificationAuthorizationBroker
  let runner: VerificationRunner

  init(
    authorizations: DesktopVerificationAuthorizationBroker,
    runner: VerificationRunner = VerificationRunner()
  ) {
    self.authorizations = authorizations
    self.runner = runner
  }

  func run(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot
  ) async throws -> [PipelineVerificationEvidence] {
    var evidence: [PipelineVerificationEvidence] = []
    var seen: Set<VerificationCommandIdentifier> = []
    for command in project.verificationCommands {
      let identifier = VerificationCommandIdentifier(command: command)
      guard seen.insert(identifier).inserted else { continue }
      let name = URL(fileURLWithPath: command.executable).lastPathComponent
      guard
        let handle = await authorizations.take(
          scope: scope,
          project: project,
          workingDirectory: workingDirectory,
          commandID: identifier
        )
      else {
        evidence.append(
          try Self.unavailable(
            identifier: identifier,
            name: name,
            reason: "A one-time local verification authorization was not issued."
          )
        )
        continue
      }
      do {
        let result = try await runner.run(
          taskID: scope.taskID.rawValue,
          generation: scope.generation,
          project: project,
          workingDirectory: workingDirectory,
          command: .identifier(identifier),
          required: true,
          authorization: handle,
          authorizationStore: authorizations.store
        )
        evidence.append(.run(result))
      } catch let error as VerificationAuthorizationError {
        evidence.append(
          try Self.unavailable(
            identifier: identifier,
            name: name,
            reason: Self.authorizationFailureReason(error)
          )
        )
      }
    }
    return evidence
  }

  private static func unavailable(
    identifier: VerificationCommandIdentifier,
    name: String,
    reason: String
  ) throws -> PipelineVerificationEvidence {
    try .makeUnavailable(
      id: identifier,
      name: name.isEmpty ? "Project verification" : name,
      required: true,
      reason: reason
    )
  }

  private static func authorizationFailureReason(
    _ error: VerificationAuthorizationError
  ) -> String {
    switch error {
    case .expired:
      "The one-time local verification authorization expired."
    case .alreadyConsumed:
      "The one-time local verification authorization was already consumed."
    case .bindingMismatch:
      "The one-time local verification authorization did not match this task generation."
    default:
      "The one-time local verification authorization was unavailable."
    }
  }
}

actor DesktopVerificationAuthorizationBroker {
  nonisolated let store: VerificationAuthorizationStore
  private var handles: [AuthorizationKey: PendingAuthorization] = [:]

  init(store: VerificationAuthorizationStore) {
    self.store = store
  }

  func authorize(
    taskID: TaskID,
    binding: ExecutionBinding,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    validFor: TimeInterval = 300
  ) async throws {
    guard let generation = Int64(exactly: binding.turnGeneration) else {
      throw VerificationAuthorizationError.invalidArgument("generation")
    }
    let now = Date()
    var seen: Set<VerificationCommandIdentifier> = []
    for command in project.verificationCommands {
      let identifier = VerificationCommandIdentifier(command: command)
      guard seen.insert(identifier).inserted else { continue }
      let key = AuthorizationKey(
        taskID: taskID,
        projectID: project.id,
        binding: binding,
        root: workingDirectory,
        commandID: identifier
      )
      if let pending = handles[key], pending.expiresAt > now { continue }
      let handle = try await store.issue(
        taskID: taskID.rawValue,
        project: project,
        workingDirectory: workingDirectory,
        command: .identifier(identifier),
        generation: generation,
        validFor: validFor
      )
      handles[key] = PendingAuthorization(
        handle: handle,
        expiresAt: now.addingTimeInterval(validFor)
      )
    }
  }

  func take(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    commandID: VerificationCommandIdentifier
  ) -> VerificationAuthorizationHandle? {
    let key = AuthorizationKey(
      taskID: scope.taskID,
      projectID: project.id,
      threadID: scope.threadID,
      turnID: scope.turnID,
      generation: UInt64(scope.generation),
      root: workingDirectory,
      commandID: commandID
    )
    guard let pending = handles.removeValue(forKey: key), pending.expiresAt > Date() else {
      return nil
    }
    return pending.handle
  }
}

private struct PendingAuthorization: Sendable {
  let handle: VerificationAuthorizationHandle
  let expiresAt: Date
}

actor DesktopVerificationAuthorizationService {
  private let coordinator: TaskCoordinator
  private let repository: ApplicationRepository
  private let broker: DesktopVerificationAuthorizationBroker

  init(
    coordinator: TaskCoordinator,
    repository: ApplicationRepository,
    broker: DesktopVerificationAuthorizationBroker
  ) {
    self.coordinator = coordinator
    self.repository = repository
    self.broker = broker
  }

  func authorize(taskID: TaskID) async throws {
    let task = try await coordinator.task(taskID)
    guard Self.mayAuthorize(task.aggregate.phase), let binding = task.aggregate.binding,
      let project = try await repository.project(id: task.aggregate.submission.projectID),
      !project.verificationCommands.isEmpty
    else { throw DesktopBackendError.operationFailed }
    try project.primaryRoot.validateCurrentIdentity()
    try await broker.authorize(
      taskID: taskID,
      binding: binding,
      project: project,
      workingDirectory: project.primaryRoot
    )
  }

  private static func mayAuthorize(_ phase: TaskPhase) -> Bool {
    phase == .running || phase == .awaitingCodexApproval || phase == .verifying
  }
}

private struct AuthorizationKey: Hashable {
  let taskID: TaskID
  let projectID: ProjectID
  let threadID: ThreadID
  let turnID: TurnID
  let generation: UInt64
  let rootDevice: UInt64
  let rootInode: UInt64
  let commandID: VerificationCommandIdentifier

  init(
    taskID: TaskID,
    projectID: ProjectID,
    binding: ExecutionBinding,
    root: RegisteredRoot,
    commandID: VerificationCommandIdentifier
  ) {
    self.init(
      taskID: taskID,
      projectID: projectID,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: binding.turnGeneration,
      root: root,
      commandID: commandID
    )
  }

  init(
    taskID: TaskID,
    projectID: ProjectID,
    threadID: ThreadID,
    turnID: TurnID,
    generation: UInt64,
    root: RegisteredRoot,
    commandID: VerificationCommandIdentifier
  ) {
    self.taskID = taskID
    self.projectID = projectID
    self.threadID = threadID
    self.turnID = turnID
    self.generation = generation
    rootDevice = root.identity.device
    rootInode = root.identity.inode
    self.commandID = commandID
  }
}
