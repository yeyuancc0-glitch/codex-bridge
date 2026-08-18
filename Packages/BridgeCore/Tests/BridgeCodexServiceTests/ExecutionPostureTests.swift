import BridgeCodexService
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import XCTest

final class ExecutionPostureTests: XCTestCase {
  func testAutoReviewAccessModeRoutesApprovalsToAutoReviewer() async throws {
    let fixture = try await makeExecutionFixture(self)
    let root = fixture.root.path
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-auto-review",
      accessMode: .autoReview
    )
    let manager = makeExecutionManager(
      script: postureExecutionScript(
        root: root,
        threadStartChecks: [
          #""sandbox":"workspace-write""#,
          #""approvalPolicy":"on-request""#,
          #""approvalsReviewer":"auto_review""#,
        ],
        turnStartChecks: [
          #""approvalPolicy":"on-request""#,
          #""approvalsReviewer":"auto_review""#,
        ],
        sandboxJSON: workspaceWriteSandboxJSON(root: root),
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review"
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(
      completed.state.resultSummary,
      "The task completed under the configured posture."
    )
  }

  func testFullAccessModeUsesDangerFullAccessAndNeverApproval() async throws {
    let fixture = try await makeExecutionFixture(self)
    let root = fixture.root.path
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-full-access",
      accessMode: .fullAccess
    )
    let script = postureExecutionScript(
      root: root,
      threadStartChecks: [
        #""sandbox":"danger-full-access""#,
        #""approvalPolicy":"never""#,
        #""approvalsReviewer":"user""#,
      ],
      turnStartChecks: [
        #""sandboxPolicy":{"type":"dangerFullAccess"}"#,
        #""approvalPolicy":"never""#,
      ],
      sandboxJSON: #"{"type":"dangerFullAccess"}"#,
      approvalPolicy: "never",
      approvalsReviewer: "user"
    )
    let manager = makeExecutionManager(script: script)
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(
      completed.state.resultSummary,
      "The task completed under the configured posture."
    )
  }

  func testFullAccessModeDowngradesWhenProjectDeniesNetwork() async throws {
    let fixture = try await makeExecutionFixture(
      self,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .denied
      )
    )
    let root = fixture.root.path
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-full-access-denied",
      accessMode: .fullAccess
    )
    let manager = makeExecutionManager(
      script: postureExecutionScript(
        root: root,
        threadStartChecks: [
          #""sandbox":"workspace-write""#,
          #""approvalPolicy":"on-request""#,
          #""approvalsReviewer":"user""#,
        ],
        turnStartChecks: [#""approvalPolicy":"on-request""#],
        sandboxJSON: workspaceWriteSandboxJSON(root: root),
        approvalPolicy: "on-request",
        approvalsReviewer: "user"
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(
      completed.state.resultSummary,
      "The task completed under the configured posture."
    )
  }

  func testFastModePassesFastServiceTierToThreadAndTurn() async throws {
    let fixture = try await makeExecutionFixture(self)
    let root = fixture.root.path
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-fast",
      fastMode: true
    )
    let manager = makeExecutionManager(
      script: postureExecutionScript(
        root: root,
        threadStartChecks: [#""serviceTier":"priority""#],
        turnStartChecks: [#""serviceTier":"priority""#],
        sandboxJSON: workspaceWriteSandboxJSON(root: root),
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        modelJSON: executionFastModelJSON
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(
      completed.state.resultSummary,
      "The task completed under the configured posture."
    )
  }

  func testFastModeFailsWhenModelDoesNotSupportFastTier() async throws {
    let fixture = try await makeExecutionFixture(self)
    let root = fixture.root.path
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-fast-unavailable",
      fastMode: true
    )
    let manager = makeExecutionManager(
      script: postureExecutionScript(
        root: root,
        threadStartChecks: [],
        sandboxJSON: workspaceWriteSandboxJSON(root: root),
        approvalPolicy: "on-request",
        approvalsReviewer: "user"
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    do {
      _ = try await coordinator.start(taskID: task.id)
      XCTFail("The fast tier should be rejected for models without a fast tier.")
    } catch let error as ExecutionServiceError {
      XCTAssertEqual(error, .serviceTierUnavailable("fast"))
    }
    let failed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "execution_start_failed")
  }

  private func workspaceWriteSandboxJSON(root: String) -> String {
    #"{"type":"workspaceWrite","networkAccess":false,"writableRoots":[""# + root
      + #""],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false}"#
  }
}
