import BridgeDomain
import BridgeSecurity

public struct ProjectThreadBinding: Equatable, Sendable {
  public let threadID: String
  public let projectID: ProjectID
  public let root: RegisteredRoot

  package init(threadID: String, projectID: ProjectID, root: RegisteredRoot) {
    self.threadID = threadID
    self.projectID = projectID
    self.root = root
  }
}

package protocol ThreadBindingRepository: Sendable {
  func binding(for threadID: String) async throws -> ProjectThreadBinding?
  func insert(_ binding: ProjectThreadBinding) async throws
}

package actor InMemoryThreadBindingRepository: ThreadBindingRepository {
  private var bindings: [String: ProjectThreadBinding] = [:]

  package init() {}

  package func binding(for threadID: String) -> ProjectThreadBinding? {
    bindings[threadID]
  }

  package func insert(_ binding: ProjectThreadBinding) throws {
    if let existing = bindings[binding.threadID] {
      guard existing == binding else { throw ProjectExecutionError.threadAlreadyBound }
      return
    }
    bindings[binding.threadID] = binding
  }
}
