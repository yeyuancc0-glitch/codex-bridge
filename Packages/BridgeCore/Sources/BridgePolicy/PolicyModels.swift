import BridgeProjects
import BridgeSecurity
import Foundation

public enum PolicyDisposition: String, Codable, Equatable, Sendable {
  case allow
  case requireLocalApproval
  case deny
}

public enum PolicyReason: String, Codable, Equatable, Sendable {
  case configuredVerification
  case trustedReadOnly
  case projectWrite
  case gitWrite
  case networkAccess
  case packageInstallation
  case destructiveOperation
  case systemWrite
  case credentialAccess
  case sensitivePath
  case outsideAllowedPath
  case sizeLimit
  case unsupportedCommand
  case malformedRequest
  case projectReadDenied
  case projectWriteDenied
  case projectNetworkDenied
  case forbiddenPath
}

public struct PolicyDecision: Codable, Equatable, Sendable {
  public let disposition: PolicyDisposition
  public let reason: PolicyReason

  public init(_ disposition: PolicyDisposition, reason: PolicyReason) {
    self.disposition = disposition
    self.reason = reason
  }
}

public struct CommandPolicyContext: Equatable, Sendable {
  public let accessPolicy: ProjectAccessPolicy
  public let verificationCommands: [VerificationCommand]

  package init(
    accessPolicy: ProjectAccessPolicy,
    verificationCommands: [VerificationCommand] = []
  ) {
    self.accessPolicy = accessPolicy
    self.verificationCommands = verificationCommands
  }

  package init(project: RegisteredProject) {
    accessPolicy = project.accessPolicy
    verificationCommands = project.verificationCommands
  }
}

public struct FileChangeRequest: Equatable, Sendable {
  public let paths: [SecureRelativePath]
  public let totalBytes: Int

  public init(paths: [SecureRelativePath], totalBytes: Int) {
    self.paths = paths
    self.totalBytes = totalBytes
  }
}

public struct FileChangeLimits: Equatable, Sendable {
  public let maximumFiles: Int
  public let maximumBytes: Int

  public init(maximumFiles: Int = 100, maximumBytes: Int = 2 * 1024 * 1024) {
    self.maximumFiles = max(1, maximumFiles)
    self.maximumBytes = max(1, maximumBytes)
  }
}
