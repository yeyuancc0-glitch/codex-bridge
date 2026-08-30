import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    let project = try await readableProject(projectID)
    return try await catalog.listThreads(
      root: project.root.canonicalPath,
      cursor: cursor,
      limit: limit,
      search: search,
      deadline: deadline
    )
  }

  public func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    let project = try await readableProject(projectID)
    return try await catalog.readThread(
      root: project.root.canonicalPath,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  public func serviceAppThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    let project = try await readableProject(projectID)
    let allowedThreadIDs = try await appThreadIDs(projectID: project.id)
    return try await catalog.listThreads(
      root: project.root.canonicalPath,
      cursor: cursor,
      limit: limit,
      search: search,
      including: allowedThreadIDs,
      deadline: deadline
    )
  }

  public func serviceAppReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    let project = try await readableProject(projectID)
    guard try await appThreadIDs(projectID: project.id).contains(threadID) else {
      throw BridgeMCPQueryError.threadNotFound
    }
    return try await catalog.readThread(
      root: project.root.canonicalPath,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  private func appThreadIDs(projectID: ProjectID) async throws -> Set<String> {
    let records = try await tasks.tasks(projectID: projectID, limit: 500)
    return Set(
      records.lazy
        .filter { $0.source.isRemoteMCPOrigin }
        .compactMap { $0.state.codexThreadID }
    )
  }
}
