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
  private let token: String

  init(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    gate: ServiceWorkspaceMutationGate,
    token: String
  ) {
    self.projectID = projectID
    self.owner = owner
    self.gate = gate
    self.token = token
  }

  public func release() async {
    await gate.releaseDirect(projectID: projectID, owner: owner, token: token)
  }
}

public actor ServiceWorkspaceMutationGate {
  private struct DirectReservation: Sendable {
    let token: String
    let owner: ServiceWorkspaceOwner
  }

  // A direct reservation is installed before the active Codex task lookup
  // awaits. That makes the reservation the single source of truth across the
  // actor re-entry point instead of relying on a check-then-set sequence.
  private var directReservations: [ProjectID: DirectReservation] = [:]
  private var codexAdmissions: [ProjectID: Set<String>] = [:]

  public init() {}

  public func activeDirectOwner(projectID: ProjectID) -> ServiceWorkspaceOwner? {
    directReservations[projectID]?.owner
  }

  public func workspaceBusyDetail(projectID: ProjectID) async throws -> WorkspaceBusyDetail? {
    if let direct = directReservations[projectID] {
      return direct.owner.busyDetail
    }
    if !(codexAdmissions[projectID] ?? []).isEmpty {
      return .codexAdmissionPending()
    }
    return nil
  }

  public func acquireDirectLease(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    activeCodexWriteTask: @Sendable () async throws -> ServiceTaskRecord?
  ) async throws -> DirectWorkspaceLease {
    if let direct = directReservations[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.owner.busyDetail)
    }
    if !(codexAdmissions[projectID] ?? []).isEmpty {
      throw ProjectWorkspaceBusyError.busy(.codexAdmissionPending())
    }
    let token = UUID().uuidString
    directReservations[projectID] = DirectReservation(token: token, owner: owner)

    do {
      if let task = try await activeCodexWriteTask() {
        removeDirectReservation(projectID: projectID, token: token)
        throw ProjectWorkspaceBusyError.busy(.codex(taskID: task.id.rawValue))
      }
    } catch {
      removeDirectReservation(projectID: projectID, token: token)
      throw error
    }
    return DirectWorkspaceLease(projectID: projectID, owner: owner, gate: self, token: token)
  }

  @discardableResult
  public func beginCodexAdmission(projectID: ProjectID) async throws -> String {
    if let direct = directReservations[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.owner.busyDetail)
    }
    let token = UUID().uuidString
    codexAdmissions[projectID, default: []].insert(token)
    return token
  }

  public func endCodexAdmission(projectID: ProjectID, token: String) {
    guard var tokens = codexAdmissions[projectID], tokens.remove(token) != nil else { return }
    codexAdmissions[projectID] = tokens.isEmpty ? nil : tokens
  }

  public func releaseDirect(projectID: ProjectID, owner: ServiceWorkspaceOwner) {
    // Keep this source-compatible fallback for older callers. New leases use
    // their opaque token so a stale lease cannot release a later reservation
    // owned by the same operation value.
    if directReservations[projectID]?.owner == owner {
      directReservations[projectID] = nil
    }
  }

  fileprivate func releaseDirect(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    token: String
  ) {
    guard let reservation = directReservations[projectID],
      reservation.token == token,
      reservation.owner == owner
    else { return }
    directReservations[projectID] = nil
  }

  private func removeDirectReservation(projectID: ProjectID, token: String) {
    guard directReservations[projectID]?.token == token else { return }
    directReservations[projectID] = nil
  }

  public func releaseAll() {
    directReservations = [:]
    codexAdmissions = [:]
  }
}

public enum ProjectWorkspaceBusyError: Error, Equatable, Sendable {
  case busy(WorkspaceBusyDetail)
}
