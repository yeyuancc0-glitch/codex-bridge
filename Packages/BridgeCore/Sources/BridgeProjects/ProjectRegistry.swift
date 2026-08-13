import BridgeDomain
import BridgeSecurity
import Foundation

public actor ProjectRegistry {
  private let repository: any ProjectRepository

  public init(repository: any ProjectRepository) {
    self.repository = repository
  }

  public func register(local registration: LocalProjectRegistration) async throws
    -> ProjectSummaryDTO
  {
    let primaryRoot = try RegisteredRoot(capturing: registration.rootURL)
    let repositoryRoot = try RegisteredRoot(
      capturing: registration.repositoryRootURL ?? registration.rootURL
    )
    guard Self.contains(parent: repositoryRoot.canonicalPath, child: primaryRoot.canonicalPath)
    else {
      throw ProjectRegistryError.repositoryDoesNotContainProject
    }

    let project = RegisteredProject(
      id: try await makeUniqueProjectID(),
      name: registration.name,
      primaryRoot: primaryRoot,
      repositoryRoot: repositoryRoot,
      accessPolicy: registration.accessPolicy,
      verificationCommands: registration.verificationCommands,
      forbiddenPatterns: registration.forbiddenPatterns,
      createdAt: Date()
    )
    try await repository.insert(project)
    return ProjectSummaryDTO(project: project)
  }

  public func addExplicitWorktree(localRootURL: URL, to projectID: ProjectID) async throws {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    let root = try RegisteredRoot(capturing: localRootURL)
    try await repository.addWorktree(root, to: projectID)
  }

  public func updateAccessPolicy(
    _ policy: ProjectAccessPolicy,
    for projectID: ProjectID
  ) async throws {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    try await repository.updateAccessPolicy(policy, for: projectID)
  }

  public func summaries() async throws -> [ProjectSummaryDTO] {
    let projects = try await repository.allProjects()
    for project in projects {
      try project.validateCurrentRoots()
    }
    return
      projects
      .sorted { $0.createdAt < $1.createdAt }
      .map(ProjectSummaryDTO.init)
  }

  public func summary(for projectID: ProjectID) async throws -> ProjectSummaryDTO {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    return ProjectSummaryDTO(project: project)
  }

  public func resolvePrimaryPath(
    projectID: ProjectID,
    relativePath: SecureRelativePath
  ) async throws -> ResolvedProjectPath {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    return try ProjectPathResolver(root: project.primaryRoot).resolve(relativePath)
  }

  public func validateThreadWorkingDirectory(
    _ localWorkingDirectoryURL: URL,
    for projectID: ProjectID
  ) async throws -> RegisteredRoot {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    let workingRoot = try RegisteredRoot(capturing: localWorkingDirectoryURL)
    let allowedRoots = [project.primaryRoot] + project.worktreeRoots
    guard allowedRoots.contains(where: { $0 == workingRoot }) else {
      throw ProjectRegistryError.workingDirectoryOutsideProject
    }
    return workingRoot
  }

  public func executionContext(
    for projectID: ProjectID,
    workingDirectoryURL: URL
  ) async throws -> ProjectExecutionContext {
    let project = try await requireProject(projectID)
    try project.validateCurrentRoots()
    let workingRoot = try RegisteredRoot(capturing: workingDirectoryURL)
    let allowedRoots = [project.primaryRoot] + project.worktreeRoots
    guard let registeredRoot = allowedRoots.first(where: { $0 == workingRoot }) else {
      throw ProjectRegistryError.workingDirectoryOutsideProject
    }
    return ProjectExecutionContext(project: project, root: registeredRoot)
  }

  private func requireProject(_ id: ProjectID) async throws -> RegisteredProject {
    guard let project = try await repository.project(id: id) else {
      throw ProjectRegistryError.unknownProject
    }
    return project
  }

  private func makeUniqueProjectID() async throws -> ProjectID {
    while true {
      let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let candidate = ProjectID(rawValue: "prj_\(random)")
      if try await repository.project(id: candidate) == nil {
        return candidate
      }
    }
  }

  private static func contains(parent: String, child: String) -> Bool {
    child == parent || child.hasPrefix(parent + "/")
  }
}
