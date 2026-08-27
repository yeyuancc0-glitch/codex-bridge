import BridgeCodexService
import BridgeServiceCore
import BridgeSupervisor
import XCTest

final class SupervisorManagerTests: XCTestCase {
  func testUnavailableSupervisorDegradesWithoutStoppingExecution() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-unavailable",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    let execution = makeExecutionManager(script: newThreadProgressScript(root: fixture.root.path))
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: unavailableSupervisorModelScript
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: execution,
      supervisor: supervisor
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed && $0.state.supervisorStatus == .degraded
    }
    XCTAssertEqual(completed.state.resultSummary, "Implemented the change and verified it.")
    XCTAssertTrue(completed.state.supervisorSummary?.contains("unavailable") == true)
  }

  func testSlowSupervisorDoesNotBlockCodexCompletion() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-slow",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    let progressDecision = supervisorDecisionJSON(
      decision: "continue",
      summary: "The running task remains within scope."
    )
    let finalDecision = supervisorDecisionJSON(
      decision: "final_accept",
      summary: "The final result remains within scope."
    )
    let execution = makeExecutionManager(script: newThreadProgressScript(root: fixture.root.path))
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: supervisorScript(
        decisions: [progressDecision, finalDecision],
        firstReviewDelay: 1
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: execution,
      supervisor: supervisor
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let executionCompleted = try await waitForTask(
      fixture,
      taskID: task.id,
      matching: { $0.state.status == .completed },
      timeout: .milliseconds(700)
    )
    XCTAssertNotEqual(executionCompleted.state.supervisorStatus, .completed)

    let reviewed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed && $0.state.supervisorStatus == .completed
    }
    XCTAssertEqual(reviewed.state.supervisorSummary, "The final result remains within scope.")
  }

  func testSupervisorSteerUsesExactActiveTurnAndExecutionCompletes() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-steer",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    let steer = supervisorDecisionJSON(
      decision: "steer",
      summary: "The plan is broader than necessary.",
      instruction: "Keep the change scoped to the requested behavior.",
      issueID: "scope-1"
    )
    let final = supervisorDecisionJSON(
      decision: "final_accept",
      summary: "The corrected implementation is accepted."
    )
    let execution = makeExecutionManager(
      script: executionWaitForSupervisorSteerScript(root: fixture.root.path)
    )
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: supervisorScript(decisions: [steer, final])
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: execution,
      supervisor: supervisor
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed && $0.state.supervisorStatus == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Completed after Supervisor steer.")
    XCTAssertEqual(completed.state.supervisorSummary, "The corrected implementation is accepted.")
  }

  func testSupervisorApprovalRequestDegradesOnlySupervisor() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-approval",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    let decision = supervisorDecisionJSON(
      decision: "continue",
      summary: "This response should not be accepted after an approval request."
    )
    let execution = makeExecutionManager(script: newThreadProgressScript(root: fixture.root.path))
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: supervisorScript(decisions: [decision], requestApproval: true)
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: execution,
      supervisor: supervisor
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let executionCompleted = try await waitForTask(
      fixture,
      taskID: task.id,
      matching: { $0.state.status == .completed },
      timeout: .seconds(10)
    )
    XCTAssertEqual(
      executionCompleted.state.resultSummary,
      "Implemented the change and verified it."
    )
    let degraded = try await waitForTask(
      fixture,
      taskID: task.id,
      matching: { $0.state.supervisorStatus == .degraded },
      timeout: .seconds(10)
    )
    XCTAssertTrue(degraded.state.supervisorSummary?.contains("approval") == true)
  }

  func testAutomaticSteerLimitConvertsFurtherSuggestionsToAttention() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-limit",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    let decisions = (1...4).map { index in
      supervisorDecisionJSON(
        decision: "steer",
        summary: "Steer suggestion \(index).",
        instruction: "Apply bounded correction \(index).",
        issueID: "issue-\(index)"
      )
    }
    let script = supervisorScript(decisions: decisions)
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: script,
      maximumAutomaticSteers: 3
    )
    addTeardownBlock { await supervisor.shutdown() }

    let launched = try await supervisor.launch(task: task)
    let handle = try XCTUnwrap(launched)
    for index in 1...4 {
      await supervisor.observe(
        try SupervisorObservation(
          kind: .progress,
          taskID: task.id,
          goal: task.prompt,
          currentStep: "Step \(index)",
          summary: "Progress observation \(index)."
        )
      )
    }

    let events = try await collectSupervisorEvents(handle.events, count: 5)
    XCTAssertEqual(events.count(where: { if case .steer = $0 { true } else { false } }), 3)
    XCTAssertEqual(events.count(where: { if case .attention = $0 { true } else { false } }), 1)
  }

  func testSeparateTasksUseIndependentSupervisorSessions() async throws {
    let fixture = try await makeExecutionFixture(self)
    let first = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-first",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium",
      permissionMode: .readOnly
    )
    let second = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-supervisor-second",
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium",
      permissionMode: .readOnly
    )
    let decision = supervisorDecisionJSON(
      decision: "continue",
      summary: "The task remains scoped."
    )
    let supervisor = try makeSupervisorManager(
      fixture: fixture,
      script: supervisorScript(decisions: [decision])
    )
    addTeardownBlock { await supervisor.shutdown() }

    let launchedFirst = try await supervisor.launch(task: first)
    let launchedSecond = try await supervisor.launch(task: second)
    let firstHandle = try XCTUnwrap(launchedFirst)
    let secondHandle = try XCTUnwrap(launchedSecond)
    await supervisor.observe(
      try SupervisorObservation(
        kind: .progress,
        taskID: first.id,
        goal: first.prompt,
        summary: "First task progress."
      )
    )
    await supervisor.observe(
      try SupervisorObservation(
        kind: .progress,
        taskID: second.id,
        goal: second.prompt,
        summary: "Second task progress."
      )
    )

    let firstEvents = try await collectSupervisorEvents(firstHandle.events, count: 2)
    let secondEvents = try await collectSupervisorEvents(secondHandle.events, count: 2)
    XCTAssertTrue(firstEvents.contains(where: { if case .decision = $0 { true } else { false } }))
    XCTAssertTrue(secondEvents.contains(where: { if case .decision = $0 { true } else { false } }))
  }
}
