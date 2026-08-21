import BridgeDomain
import BridgeSecurity
import Foundation

public protocol ProjectRepository: Sendable {
  func allProjects() async throws -> [RegisteredProject]
  func project(id: ProjectID) async throws -> RegisteredProject?
  func insert(_ project: RegisteredProject) async throws
  func addWorktree(_ root: RegisteredRoot, to projectID: ProjectID) async throws
  func updateAccessPolicy(_ policy: ProjectAccessPolicy, for projectID: ProjectID) async throws
}

public protocol MutableProjectRepository: ProjectRepository {
  func removeProject(id: ProjectID) async throws
}

public protocol ProjectRootRebindingRepository: ProjectRepository {
  func rebindSingleRoot(_ root: RegisteredRoot, for projectID: ProjectID) async throws
}

public actor InMemoryProjectRepository: MutableProjectRepository,
  ProjectRootRebindingRepository
{
  private var projectsByID: [ProjectID: RegisteredProject] = [:]

  public init() {}

  public func allProjects() -> [RegisteredProject] {
    Array(projectsByID.values)
  }

  public func project(id: ProjectID) -> RegisteredProject? {
    projectsByID[id]
  }

  public func insert(_ project: RegisteredProject) throws {
    guard projectsByID[project.id] == nil else {
      throw ProjectRegistryError.duplicateProjectID
    }
    guard !containsRegisteredRoot(project.primaryRoot) else {
      throw ProjectRegistryError.duplicateRoot
    }
    projectsByID[project.id] = project
  }

  public func addWorktree(_ root: RegisteredRoot, to projectID: ProjectID) throws {
    guard let project = projectsByID[projectID] else {
      throw ProjectRegistryError.unknownProject
    }
    guard !containsRegisteredRoot(root) else {
      throw ProjectRegistryError.duplicateRoot
    }
    projectsByID[projectID] = project.addingWorktree(root)
  }

  public func updateAccessPolicy(
    _ policy: ProjectAccessPolicy,
    for projectID: ProjectID
  ) throws {
    guard let project = projectsByID[projectID] else {
      throw ProjectRegistryError.unknownProject
    }
    projectsByID[projectID] = project.updatingAccessPolicy(policy)
  }

  public func removeProject(id: ProjectID) throws {
    guard projectsByID.removeValue(forKey: id) != nil else {
      throw ProjectRegistryError.unknownProject
    }
  }

  public func rebindSingleRoot(_ root: RegisteredRoot, for projectID: ProjectID) throws {
    guard let project = projectsByID[projectID] else {
      throw ProjectRegistryError.unknownProject
    }
    guard project.primaryRoot.canonicalPath == project.repositoryRoot.canonicalPath,
      project.worktreeRoots.isEmpty
    else { throw ProjectRegistryError.rootRebindingUnsupported }
    guard root.canonicalPath == project.primaryRoot.canonicalPath else {
      throw ProjectRegistryError.rootSelectionMismatch
    }
    guard project.primaryRoot != root else { return }
    guard !containsRegisteredRoot(root, excluding: projectID) else {
      throw ProjectRegistryError.duplicateRoot
    }
    projectsByID[projectID] = project.replacingSingleRoot(root)
  }

  private func containsRegisteredRoot(_ candidate: RegisteredRoot) -> Bool {
    containsRegisteredRoot(candidate, excluding: nil)
  }

  private func containsRegisteredRoot(
    _ candidate: RegisteredRoot,
    excluding projectID: ProjectID?
  ) -> Bool {
    projectsByID.values.contains { project in
      guard project.id != projectID else { return false }
      return project.primaryRoot.canonicalPath == candidate.canonicalPath
        || project.primaryRoot.identity == candidate.identity
        || project.worktreeRoots.contains(where: {
          $0.canonicalPath == candidate.canonicalPath || $0.identity == candidate.identity
        })
    }
  }
}
