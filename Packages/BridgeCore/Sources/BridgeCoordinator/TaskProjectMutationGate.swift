import BridgeDomain
import Foundation

public enum TaskProjectMutationGateError: Error, Equatable, Sendable {
  case removalInProgress(ProjectID)
  case submissionsInProgress(ProjectID)
  case capacityExceeded(maximum: Int)
}

public struct TaskProjectSubmissionLease: Sendable {
  fileprivate let id: UUID
  fileprivate let projectID: ProjectID
}

public struct TaskProjectRemovalLease: Sendable {
  fileprivate let id: UUID
  fileprivate let projectID: ProjectID
}

public actor TaskProjectMutationGate {
  private let maximumConcurrentOperations: Int
  private var submissions: [UUID: ProjectID] = [:]
  private var removals: [ProjectID: UUID] = [:]

  public init(maximumConcurrentOperations: Int = 4_096) {
    self.maximumConcurrentOperations = max(1, maximumConcurrentOperations)
  }

  public func acquireSubmission(for projectID: ProjectID) throws -> TaskProjectSubmissionLease {
    guard removals[projectID] == nil else {
      throw TaskProjectMutationGateError.removalInProgress(projectID)
    }
    guard submissions.count + removals.count < maximumConcurrentOperations else {
      throw TaskProjectMutationGateError.capacityExceeded(maximum: maximumConcurrentOperations)
    }
    let lease = TaskProjectSubmissionLease(id: UUID(), projectID: projectID)
    submissions[lease.id] = projectID
    return lease
  }

  public func releaseSubmission(_ lease: TaskProjectSubmissionLease) {
    guard submissions[lease.id] == lease.projectID else { return }
    submissions.removeValue(forKey: lease.id)
  }

  public func acquireRemoval(for projectID: ProjectID) throws -> TaskProjectRemovalLease {
    guard removals[projectID] == nil else {
      throw TaskProjectMutationGateError.removalInProgress(projectID)
    }
    guard !submissions.values.contains(projectID) else {
      throw TaskProjectMutationGateError.submissionsInProgress(projectID)
    }
    guard submissions.count + removals.count < maximumConcurrentOperations else {
      throw TaskProjectMutationGateError.capacityExceeded(maximum: maximumConcurrentOperations)
    }
    let lease = TaskProjectRemovalLease(id: UUID(), projectID: projectID)
    removals[projectID] = lease.id
    return lease
  }

  public func releaseRemoval(_ lease: TaskProjectRemovalLease) {
    guard removals[lease.projectID] == lease.id else { return }
    removals.removeValue(forKey: lease.projectID)
  }
}
