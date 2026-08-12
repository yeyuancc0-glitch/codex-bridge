import BridgeCoordinator
import BridgeDomain
import BridgeProjects
import Foundation
import XCTest

final class DefaultTaskAdmissionPolicyTests: XCTestCase {
  func testProjectCapabilitiesAreHardAdmissionBounds() async throws {
    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "coordinator-policy-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let registration = try LocalProjectRegistration(
      name: "Policy fixture",
      rootURL: root,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .requiresLocalApproval,
        network: .denied
      )
    )
    let project = try await registry.register(local: registration)
    let policy = DefaultTaskAdmissionPolicy(registry: registry)

    let read = makeSubmission(projectID: project.id, mode: "read-only", network: false)
    let write = makeSubmission(projectID: project.id, mode: "workspace-write", network: false)
    let network = makeSubmission(projectID: project.id, mode: "read-only", network: true)
    let readDecision = try await policy.decision(for: read)
    let writeDecision = try await policy.decision(for: write)
    XCTAssertEqual(readDecision, .start)
    XCTAssertEqual(writeDecision, .requireLocalApproval)
    do {
      _ = try await policy.decision(for: network)
      XCTFail("Expected denied network admission")
    } catch {
      XCTAssertEqual(error as? TaskCoordinatorError, .projectNetworkDenied)
    }
  }

  private func makeSubmission(
    projectID: ProjectID,
    mode: String,
    network: Bool
  ) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: UUID().uuidString),
      projectID: projectID,
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-test",
        effort: "medium",
        permissionMode: mode,
        networkAccess: network
      ),
      supervisor: SupervisorOptions(enabled: false, model: "", effort: ""),
      contract: TaskContract(goal: "Test", acceptanceCriteria: ["Pass"])
    )
  }
}
