import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation

public actor ServiceProjectRepositoryAdapter: ProjectRepository {
  private let projects: ServiceProjectService

  public init(projects: ServiceProjectService) {
    self.projects = projects
  }

  public func allProjects() async throws -> [RegisteredProject] {
    try await projects.projects().map(Self.registeredProject)
  }

  public func project(id: ProjectID) async throws -> RegisteredProject? {
    try await projects.project(id: id).map(Self.registeredProject)
  }

  public func insert(_ project: RegisteredProject) async throws {
    guard project.primaryRoot == project.repositoryRoot, project.worktreeRoots.isEmpty else {
      throw ProjectRegistryError.repositoryDoesNotContainProject
    }
    _ = try await projects.register(
      name: project.name,
      rootURL: URL(fileURLWithPath: project.primaryRoot.canonicalPath, isDirectory: true),
      accessPolicy: project.accessPolicy,
      id: project.id
    )
  }

  public func addWorktree(_ root: RegisteredRoot, to projectID: ProjectID) async throws {
    _ = root
    _ = projectID
    throw ProjectRegistryError.rootRebindingUnsupported
  }

  public func updateAccessPolicy(
    _ policy: ProjectAccessPolicy,
    for projectID: ProjectID
  ) async throws {
    _ = try await projects.updateAccessPolicy(policy, projectID: projectID)
  }

  private static func registeredProject(_ source: ServiceProjectRecord) throws
    -> RegisteredProject
  {
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: source.root.canonicalPath, isDirectory: true)
    )
    guard root.identity.device == source.root.device,
      root.identity.inode == source.root.inode
    else {
      throw ServiceStoreError.invalidArgument("project.rootIdentity")
    }
    return RegisteredProject(
      id: source.id,
      name: source.name,
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: source.accessPolicy,
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: source.createdAt
    )
  }
}
