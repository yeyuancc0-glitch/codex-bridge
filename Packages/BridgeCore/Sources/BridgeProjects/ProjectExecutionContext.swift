import BridgeDomain
import BridgeSecurity

public struct ProjectExecutionContext: Equatable, Sendable {
  public let projectID: ProjectID
  public let root: RegisteredRoot
  public let accessPolicy: ProjectAccessPolicy
  public let verificationCommands: [VerificationCommand]
  public let forbiddenPatterns: [ForbiddenPathPattern]

  package init(project: RegisteredProject, root: RegisteredRoot) {
    projectID = project.id
    self.root = root
    accessPolicy = project.accessPolicy
    verificationCommands = project.verificationCommands
    forbiddenPatterns = project.forbiddenPatterns
  }
}
