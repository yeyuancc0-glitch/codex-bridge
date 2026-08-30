import BridgeMCP
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  public func serviceListSkills(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillList {
    try Self.checkDeadline(deadline)
    let root: URL?
    if let projectID {
      root = URL(fileURLWithPath: try await readableProject(projectID).root.canonicalPath)
    } else {
      root = nil
    }
    do {
      let manifests = try await skillScanner.scanSkills(for: root)
      return MCPServiceSkillList(skills: manifests.map(MCPServiceSkill.init))
    } catch {
      throw Self.publicSkillError(error)
    }
  }

  public func serviceReadSkill(
    skillName: String,
    projectID: String?,
    subpath: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillDocument {
    try Self.checkDeadline(deadline)
    guard skillName.utf8.count <= 128, !skillName.isEmpty else {
      throw BridgeMCPQueryError.contractRejected
    }
    let root: URL?
    if let projectID {
      root = URL(fileURLWithPath: try await readableProject(projectID).root.canonicalPath)
    } else {
      root = nil
    }
    do {
      let manifests = try await skillScanner.scanSkills(for: root)
      guard let manifest = manifests.first(where: { $0.name == skillName }) else {
        throw BridgeMCPQueryError.skillNotFound
      }
      return MCPServiceSkillDocument(
        document: try await skillScanner.readSkillDocument(manifest, subpath: subpath)
      )
    } catch let error as BridgeMCPQueryError {
      throw error
    } catch {
      throw Self.publicSkillError(error)
    }
  }
}
