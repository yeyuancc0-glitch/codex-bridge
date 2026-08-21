import BridgeMCP
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  public func serviceRunSkillAction(
    _ request: MCPRunSkillActionRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    guard request.arguments.count <= 128,
      request.arguments.allSatisfy({ $0.utf8.count <= 4_096 })
    else { throw BridgeMCPQueryError.contractRejected }
    let manifests: [SkillManifest]
    do {
      manifests = try await skillScanner.scanSkills(
        for: URL(fileURLWithPath: project.root.canonicalPath)
      )
    } catch {
      throw Self.publicSkillError(error)
    }
    guard let manifest = manifests.first(where: { $0.name == request.skillName }) else {
      throw BridgeMCPQueryError.skillNotFound
    }
    let launch: SkillScanner.SkillActionLaunch
    do {
      launch = try await skillScanner.resolveAction(request.actionName, in: manifest)
    } catch {
      throw Self.publicSkillError(error)
    }
    let argv = launch.argvPrefix + request.arguments
    let requiresNetwork = launch.action.networkRequirement != .denied
    // Only an explicit denial enters the network sandbox. Unspecified actions
    // are conservatively treated as network-capable by project policy and local
    // approval; guessing `denied` would break legitimate loopback/network tools.
    let denyNetwork = launch.action.networkRequirement == .denied
    let directRequest = MCPDirectExecRequest(
      projectID: request.projectID,
      argv: argv,
      workingDirectory: nil,
      tty: false,
      yieldTimeMS: request.yieldTimeMS,
      timeoutMS: request.timeoutMS,
      clientRequestID: request.clientRequestID
    )
    return try await serviceDirectExecCommand(
      directRequest,
      deadline: deadline,
      isValidatedSkillScript: true,
      requiresNetwork: requiresNetwork,
      denyNetwork: denyNetwork
    )
  }
}
