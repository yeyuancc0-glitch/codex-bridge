import BridgeDomain
import BridgeProjects
import Foundation

public actor ServiceProjectService {
  private let store: SimpleServiceStore
  private let makeProjectID: @Sendable () -> ProjectID
  private let now: @Sendable () -> Date

  public init(
    store: SimpleServiceStore,
    makeProjectID: @escaping @Sendable () -> ProjectID = {
      ProjectID(rawValue: "prj-" + UUID().uuidString.lowercased())
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.makeProjectID = makeProjectID
    self.now = now
  }

  @discardableResult
  public func register(
    name: String,
    rootURL: URL,
    accessPolicy: ProjectAccessPolicy = .init(),
    id requestedID: ProjectID? = nil
  ) async throws -> ServiceProjectRecord {
    let date = now()
    let project = try ServiceProjectRecord(
      id: requestedID ?? makeProjectID(),
      name: name,
      root: ServiceRootIdentity(capturing: rootURL),
      accessPolicy: accessPolicy,
      createdAt: date,
      updatedAt: date
    )
    try await store.insertProject(project)
    return project
  }

  public func project(id: ProjectID) async throws -> ServiceProjectRecord? {
    guard let project = try await store.project(id: id) else { return nil }
    return try await refreshLegacyRootIfPossible(project)
  }

  public func projects() async throws -> [ServiceProjectRecord] {
    try await store.projects()
  }

  @discardableResult
  public func updateAccessPolicy(
    _ policy: ProjectAccessPolicy,
    projectID: ProjectID
  ) async throws -> ServiceProjectRecord {
    guard let current = try await store.project(id: projectID) else {
      throw ServiceStoreError.unknownProject(projectID)
    }
    let updated = try current.updatingAccessPolicy(policy, at: now())
    try await store.updateProject(updated)
    return updated
  }

  @discardableResult
  public func updateWorkspaceConfiguration(
    directCommandMode: ServiceDirectCommandMode,
    workspaceCommands: [ServiceWorkspaceCommand],
    commandBlacklist: [ServiceCommandBlacklistRule] = [],
    projectID: ProjectID
  ) async throws -> ServiceProjectRecord {
    guard let current = try await store.project(id: projectID) else {
      throw ServiceStoreError.unknownProject(projectID)
    }
    let updated = try current.updatingWorkspaceConfiguration(
      directCommandMode: directCommandMode,
      workspaceCommands: workspaceCommands,
      commandBlacklist: commandBlacklist,
      at: now()
    )
    try await store.updateProject(updated)
    return updated
  }

  @discardableResult
  public func updateWorkspaceCommands(
    _ workspaceCommands: [ServiceWorkspaceCommand],
    commandBlacklist: [ServiceCommandBlacklistRule],
    projectID: ProjectID
  ) async throws -> ServiceProjectRecord {
    try await store.updateWorkspaceConfiguration(
      projectID: projectID,
      directCommandMode: nil,
      workspaceCommands: workspaceCommands,
      commandBlacklist: commandBlacklist,
      at: now()
    )
    guard let updated = try await store.project(id: projectID) else {
      throw ServiceStoreError.unknownProject(projectID)
    }
    return updated
  }

  @discardableResult
  public func updateDirectCommandMode(
    _ mode: ServiceDirectCommandMode,
    projectID: ProjectID
  ) async throws -> ServiceProjectRecord {
    try await store.updateWorkspaceConfiguration(
      projectID: projectID,
      directCommandMode: mode,
      workspaceCommands: nil,
      commandBlacklist: nil,
      at: now()
    )
    guard let updated = try await store.project(id: projectID) else {
      throw ServiceStoreError.unknownProject(projectID)
    }
    return updated
  }

  public func remove(projectID: ProjectID) async throws {
    try await store.removeProject(id: projectID)
  }

  private func refreshLegacyRootIfPossible(
    _ project: ServiceProjectRecord
  ) async throws -> ServiceProjectRecord {
    guard project.root.volumeUUID == nil,
      let current = try? ServiceRootIdentity(
        capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
      ),
      current.canonicalPath == project.root.canonicalPath,
      current.inode == project.root.inode,
      current.volumeUUID != nil
    else {
      return project
    }
    try await store.refreshLegacyProjectRoot(
      projectID: project.id,
      expected: project.root,
      replacement: current
    )
    guard let refreshed = try await store.project(id: project.id) else {
      throw ServiceStoreError.unknownProject(project.id)
    }
    return refreshed
  }
}
