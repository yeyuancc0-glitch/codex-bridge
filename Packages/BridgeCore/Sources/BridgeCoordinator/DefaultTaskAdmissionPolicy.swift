import BridgeDomain
import BridgeProjects

public struct DefaultTaskAdmissionPolicy: TaskAdmissionPolicy {
  private let registry: ProjectRegistry

  public init(registry: ProjectRegistry) {
    self.registry = registry
  }

  public func decision(for submission: TaskSubmission) async throws -> TaskAdmissionDecision {
    let capabilities = try await registry.summary(for: submission.projectID).capabilities
    guard capabilities.read == .allowed else {
      throw TaskCoordinatorError.projectReadDenied
    }
    switch submission.execution.permissionMode {
    case "read-only":
      break
    case "workspace-write":
      guard capabilities.write != .denied else {
        throw TaskCoordinatorError.projectWriteDenied
      }
      return .requireLocalApproval
    default:
      throw TaskCoordinatorError.unsupportedPermissionMode(
        submission.execution.permissionMode
      )
    }
    guard submission.execution.networkAccess else { return .start }
    guard capabilities.network != .denied else {
      throw TaskCoordinatorError.projectNetworkDenied
    }
    return .requireLocalApproval
  }
}
