import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class AgentSteerTests: XCTestCase {
  func testCoordinatorRoutesAgentSteerAndPersistsUserMessage() async throws {
    let fixture = try await makeExecutionFixture(self)
    let taskID = TaskID(rawValue: "tsk-agent-steer")
    let submitted = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .chatGPT,
        clientRequestID: "request-agent-steer",
        prompt: "Inspect the repository.",
        providerID: "opencode",
        installationID: "ainst-agent-steer",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      ),
      taskID: taskID
    )
    _ = try await fixture.tasks.begin(taskID: submitted.task.id)
    let runner = SteerableAgentRunner()
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: makeExecutionManager(script: "exit 0"),
      agentRunner: runner
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: taskID)
    let running = try await waitForTask(fixture, taskID: taskID) {
      $0.state.status == .running
    }
    let runID = try XCTUnwrap(running.state.providerRunID)
    try await coordinator.steer(
      taskID: taskID,
      expectedTurnID: runID,
      text: "Focus on the failing test."
    )
    try await coordinator.steer(
      taskID: taskID,
      expectedTurnID: runID,
      text: "Stop the current attempt and summarize.",
      interruptCurrentPrompt: true
    )

    let steerInputs = await runner.steerInputs
    let immediateSteerInputs = await runner.immediateSteerInputs
    XCTAssertEqual(steerInputs, ["Focus on the failing test."])
    XCTAssertEqual(immediateSteerInputs, ["Stop the current attempt and summarize."])
    let messages = try await coordinator.conversationPage(taskID: taskID)
    XCTAssertTrue(
      messages.contains { $0.role == .user && $0.content == "Focus on the failing test." }
    )
    XCTAssertTrue(
      messages.contains {
        $0.role == .user && $0.content == "Stop the current attempt and summarize."
      }
    )
  }
}

private actor SteerableAgentRunner: AgentTaskRunning {
  private var continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation?
  private(set) var steerInputs: [String] = []
  private(set) var immediateSteerInputs: [String] = []

  func start(_ brief: AgentTaskBrief) async throws -> AgentTaskRunHandle {
    let pair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self
    )
    continuation = pair.continuation
    return AgentTaskRunHandle(
      sessionID: "session-\(brief.taskID.rawValue)",
      runID: "run-\(brief.taskID.rawValue)",
      events: pair.stream,
      interrupt: {},
      steer: { [weak self] text in
        await self?.recordSteer(text)
      },
      interruptAndSteer: { [weak self] text in
        await self?.recordImmediateSteer(text)
      },
      shutdown: { [weak self] in
        await self?.finish()
      }
    )
  }

  func recordSteer(_ text: String) {
    steerInputs.append(text)
  }

  func recordImmediateSteer(_ text: String) {
    immediateSteerInputs.append(text)
  }

  func finish() {
    continuation?.finish()
    continuation = nil
  }
}
