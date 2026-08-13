import BridgeDomain
import XCTest

@testable import BridgeCoordinator

final class TaskProjectMutationGateTests: XCTestCase {
  func testRemovalAndSubmissionLeasesAreMutuallyExclusivePerProject() async throws {
    let gate = TaskProjectMutationGate()
    let projectID = ProjectID(rawValue: "prj-gated")
    let submission = try await gate.acquireSubmission(for: projectID)

    do {
      _ = try await gate.acquireRemoval(for: projectID)
      XCTFail("Expected an in-flight submission to block removal")
    } catch {
      XCTAssertEqual(
        error as? TaskProjectMutationGateError,
        .submissionsInProgress(projectID)
      )
    }

    await gate.releaseSubmission(submission)
    let removal = try await gate.acquireRemoval(for: projectID)
    do {
      _ = try await gate.acquireSubmission(for: projectID)
      XCTFail("Expected removal to block new submissions")
    } catch {
      XCTAssertEqual(
        error as? TaskProjectMutationGateError,
        .removalInProgress(projectID)
      )
    }
    await gate.releaseRemoval(removal)
    let accepted = try await gate.acquireSubmission(for: projectID)
    await gate.releaseSubmission(accepted)
  }

  func testProjectLeasesDoNotBlockUnrelatedProjects() async throws {
    let gate = TaskProjectMutationGate()
    let removal = try await gate.acquireRemoval(for: ProjectID(rawValue: "prj-one"))

    let submission = try await gate.acquireSubmission(for: ProjectID(rawValue: "prj-two"))

    await gate.releaseSubmission(submission)
    await gate.releaseRemoval(removal)
  }
}
