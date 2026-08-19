import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

public enum ServiceWorkspaceOwner: Codable, Equatable, Sendable {
  case directFileOperation(operationID: String)
  case directCommand(sessionID: String)
  case directGitCommit(operationID: String)

  public var ownerCode: String {
    switch self {
    case .directFileOperation:
      "direct_file"
    case .directCommand:
      "direct_command"
    case .directGitCommit:
      "direct_git_commit"
    }
  }

  public var busyDetail: WorkspaceBusyDetail {
    switch self {
    case .directFileOperation(let operationID):
      .direct(owner: "direct_file", operationID: operationID)
    case .directCommand(let sessionID):
      .direct(owner: "direct_command", sessionID: sessionID)
    case .directGitCommit(let operationID):
      .direct(owner: "direct_git_commit", operationID: operationID)
    }
  }
}

public struct DirectWorkspaceLease: Sendable {
  public let projectID: ProjectID
  public let owner: ServiceWorkspaceOwner
  private let gate: ServiceWorkspaceMutationGate

  init(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    gate: ServiceWorkspaceMutationGate
  ) {
    self.projectID = projectID
    self.owner = owner
    self.gate = gate
  }

  public func release() async {
    await gate.releaseDirect(projectID: projectID, owner: owner)
  }
}

public actor ServiceWorkspaceMutationGate {
  private var directLeases: [ProjectID: ServiceWorkspaceOwner] = [:]
  private var pendingCodexAdmissions: Set<ProjectID> = []

  public init() {}

  public func activeDirectOwner(projectID: ProjectID) -> ServiceWorkspaceOwner? {
    directLeases[projectID]
  }

  public func workspaceBusyDetail(projectID: ProjectID) async throws -> WorkspaceBusyDetail? {
    if let direct = directLeases[projectID] {
      return direct.busyDetail
    }
    if pendingCodexAdmissions.contains(projectID) {
      return .codexAdmissionPending()
    }
    return nil
  }

  public func acquireDirectLease(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    activeCodexWriteTask: @Sendable () async throws -> ServiceTaskRecord?
  ) async throws -> DirectWorkspaceLease {
    if let direct = directLeases[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.busyDetail)
    }
    if pendingCodexAdmissions.contains(projectID) {
      throw ProjectWorkspaceBusyError.busy(.codexAdmissionPending())
    }
    if let task = try await activeCodexWriteTask() {
      throw ProjectWorkspaceBusyError.busy(.codex(taskID: task.id.rawValue))
    }
    directLeases[projectID] = owner
    return DirectWorkspaceLease(projectID: projectID, owner: owner, gate: self)
  }

  public func beginCodexAdmission(projectID: ProjectID) async throws {
    if let direct = directLeases[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.busyDetail)
    }
    pendingCodexAdmissions.insert(projectID)
  }

  public func endCodexAdmission(projectID: ProjectID) {
    pendingCodexAdmissions.remove(projectID)
  }

  public func releaseDirect(projectID: ProjectID, owner: ServiceWorkspaceOwner) {
    if directLeases[projectID] == owner {
      directLeases[projectID] = nil
    }
  }

  public func releaseAll() {
    directLeases = [:]
    pendingCodexAdmissions = []
  }
}

public enum ProjectWorkspaceBusyError: Error, Equatable, Sendable {
  case busy(WorkspaceBusyDetail)
}
