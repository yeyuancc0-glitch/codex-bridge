import BridgeCoordinator
import BridgeDomain
import BridgePersistence
import BridgeProjects
import BridgeRepositories
import Foundation

struct DesktopComposition: Sendable {
  let eventStore: EventStore
  let repository: ApplicationRepository
  let registry: ProjectRegistry
  let coordinator: TaskCoordinator

  static func make(dataDirectoryURL: URL) async throws -> DesktopComposition {
    let paths = try DesktopDataStore.prepare(at: dataDirectoryURL)
    let eventStore = try EventStore(path: paths.eventStoreURL.path)
    let repository = try ApplicationRepository(path: paths.applicationRepositoryURL.path)
    let registry = ProjectRegistry(repository: repository)
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: DefaultTaskAdmissionPolicy(registry: registry),
      runtime: UnavailableDesktopTaskRuntime()
    )
    _ = try await coordinator.recoverIncompleteTasks()
    return DesktopComposition(
      eventStore: eventStore,
      repository: repository,
      registry: registry,
      coordinator: coordinator
    )
  }
}

private struct UnavailableDesktopTaskRuntime: TaskExecutionRuntime {
  func lockKeys(for _: TaskSubmission) throws -> [String] {
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func start(taskID _: TaskID, submission _: TaskSubmission) throws -> TaskExecutionSession {
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) throws {
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func steer(taskID _: TaskID, binding _: ExecutionBinding, prompt _: String) throws {
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) throws {
    throw DesktopBackendError.taskPipelineUnavailable
  }
}
