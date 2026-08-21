import BridgeProjects
import BridgeSecurity

public struct FileChangePolicy: Sendable {
  private let sensitivePaths: SensitivePathPolicy
  private let limits: FileChangeLimits

  public init(
    sensitivePaths: SensitivePathPolicy = .init(),
    limits: FileChangeLimits = .init()
  ) {
    self.sensitivePaths = sensitivePaths
    self.limits = limits
  }

  package func evaluate(
    _ request: FileChangeRequest,
    allowedPathPrefixes: [SecureRelativePath],
    accessPolicy: ProjectAccessPolicy,
    forbiddenPatterns: [ForbiddenPathPattern]
  ) -> PolicyDecision {
    guard request.totalBytes >= 0, !request.paths.isEmpty else {
      return PolicyDecision(.deny, reason: .malformedRequest)
    }
    guard request.paths.allSatisfy(sensitivePaths.allows) else {
      return PolicyDecision(.deny, reason: .sensitivePath)
    }
    guard request.paths.allSatisfy({ isAllowed($0, prefixes: allowedPathPrefixes) }) else {
      return PolicyDecision(.deny, reason: .outsideAllowedPath)
    }
    guard
      request.paths.allSatisfy({ path in
        !forbiddenPatterns.contains(where: { ForbiddenPathMatcher.matches($0, path: path) })
      })
    else {
      return PolicyDecision(.deny, reason: .forbiddenPath)
    }
    guard accessPolicy.write != .denied else {
      return PolicyDecision(.deny, reason: .projectWriteDenied)
    }
    guard request.paths.count <= limits.maximumFiles,
      request.totalBytes <= limits.maximumBytes
    else {
      return PolicyDecision(.requireLocalApproval, reason: .sizeLimit)
    }
    let disposition: PolicyDisposition =
      accessPolicy.write == .allowed ? .allow : .requireLocalApproval
    return PolicyDecision(disposition, reason: .projectWrite)
  }

  private func isAllowed(
    _ path: SecureRelativePath,
    prefixes: [SecureRelativePath]
  ) -> Bool {
    guard !prefixes.isEmpty else { return true }
    return prefixes.contains { prefix in
      path.components.starts(with: prefix.components)
    }
  }
}
