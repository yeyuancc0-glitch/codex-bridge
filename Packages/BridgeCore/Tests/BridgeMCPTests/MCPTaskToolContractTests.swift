import BridgeDomain
import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPTaskToolContractTests: XCTestCase {
  func testTaskToolsAreAdvertisedOnlyWhenOperationsAreInjected() async throws {
    XCTAssertEqual(MCPToolCatalog().definitions.count, 5)
    XCTAssertEqual(MCPToolCatalog(includeTaskTools: true).definitions.count, 12)

    let transport = await InMemoryTransport.createConnectedPair()
    let factory = MCPServerFactory(
      appVersion: "0.1.0",
      queries: TaskNoopQueries(),
      taskOperations: RecordingTaskOperations()
    )
    let server = await factory.makeServer()
    let client = Client(name: "task-tools-test", version: "1", configuration: .strict)
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }
    try await server.start(transport: transport.server)
    _ = try await client.connect(transport: transport.client)
    let tools = try await client.listTools()
    XCTAssertEqual(tools.tools.count, 12)
  }

  func testTaskReadsUseBoundedCursorContractsAndStructuredParity() async throws {
    let operations = RecordingTaskOperations()
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations
    )

    let task = try await dispatcher.call(
      .init(name: "get_task", arguments: ["task_id": "tsk_1"])
    )
    XCTAssertEqual(try object(task)["task"]?.objectValue?["phase"], "running")

    let events = try await dispatcher.call(
      .init(
        name: "get_task_events",
        arguments: ["task_id": "tsk_1", "after_seq": 120, "limit": 2]
      )
    )
    let eventsObject = try object(events)
    XCTAssertEqual(eventsObject["events"]?.arrayValue?.first?.objectValue?["seq"], 121)
    XCTAssertEqual(eventsObject["next_after_seq"], 122)
    let eventRequest = await operations.lastEventRequest
    XCTAssertEqual(eventRequest?.taskID, "tsk_1")
    XCTAssertEqual(eventRequest?.afterSequence, 120)
    XCTAssertEqual(eventRequest?.limit, 2)

    let diff = try await dispatcher.call(
      .init(
        name: "get_task_diff",
        arguments: [
          "task_id": "tsk_1", "cursor": "patch:1", "limit": 1, "include_patch": true,
        ]
      )
    )
    let diffObject = try object(diff)
    XCTAssertEqual(diffObject["files"]?.arrayValue?.first?.objectValue?["relative_path"], "a.swift")
    XCTAssertEqual(diffObject["patch"], "@@ bounded patch @@")
    let diffRequest = await operations.lastDiffRequest
    XCTAssertEqual(diffRequest?.cursor, "patch:1")
    XCTAssertEqual(diffRequest?.includePatch, true)

    let report = try await dispatcher.call(
      .init(name: "get_final_report", arguments: ["task_id": "tsk_1"])
    )
    XCTAssertEqual(try object(report)["report"]?.objectValue?["status"], "completed")
  }

  func testSubmitParsesAndDelegatesCompleteContractWithoutSDKTypes() async throws {
    let operations = RecordingTaskOperations()
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations
    )

    let first = try await dispatcher.call(
      .init(name: "submit_task", arguments: submissionArguments())
    )
    let second = try await dispatcher.call(
      .init(name: "submit_task", arguments: submissionArguments())
    )

    XCTAssertEqual(try object(first)["task_id"], "tsk_1")
    XCTAssertEqual(try object(first)["reused_existing_task"], false)
    XCTAssertEqual(try object(second)["task_id"], "tsk_1")
    XCTAssertEqual(try object(second)["reused_existing_task"], true)
    let submitCount = await operations.submitCount
    XCTAssertEqual(submitCount, 2)

    let recordedSubmission = await operations.lastSubmission
    let submission = try XCTUnwrap(recordedSubmission)
    XCTAssertEqual(submission.idempotencyKey.rawValue, "conversation-1:message-4")
    XCTAssertEqual(submission.projectID.rawValue, "prj_alpha")
    XCTAssertEqual(submission.execution.permissionMode, "workspace-write")
    XCTAssertEqual(submission.execution.networkAccess, false)
    XCTAssertEqual(submission.supervisor.enabled, true)
    XCTAssertEqual(submission.contract.acceptanceCriteria, ["Tests pass"])
    XCTAssertEqual(submission.contract.allowedPaths, ["Packages/BridgeCore"])
    guard case .existing(let threadID) = submission.thread else {
      return XCTFail("Expected the existing thread target.")
    }
    XCTAssertEqual(threadID.rawValue, "thr_1")
  }

  func testSteerRequiresExpectedTurnAndInterruptDoesNotExposeApprovalTool() async throws {
    let operations = RecordingTaskOperations()
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations
    )

    let steer = try await dispatcher.call(
      .init(
        name: "steer_task",
        arguments: [
          "task_id": "tsk_1", "expected_turn_id": "turn_9", "input": "Keep one state source.",
        ]
      )
    )
    XCTAssertEqual(try object(steer)["accepted"], true)
    let steerRequest = await operations.lastSteerRequest
    XCTAssertEqual(steerRequest?.expectedTurnID, "turn_9")
    XCTAssertEqual(steerRequest?.input, "Keep one state source.")

    let interrupt = try await dispatcher.call(
      .init(name: "interrupt_task", arguments: ["task_id": "tsk_1"])
    )
    XCTAssertEqual(try object(interrupt)["operation_id"], "op_interrupt")

    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(name: "steer_task", arguments: ["task_id": "tsk_1", "input": "wrong turn"])
      )
    }
    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(name: "respond_to_codex_approval", arguments: [:])
      )
    }
  }

  func testUnknownFieldsAreRejectedAtEveryTaskContractLevel() async {
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: RecordingTaskOperations()
    )

    var root = submissionArguments()
    root["unexpected"] = true
    await assertInvalidParams {
      _ = try await dispatcher.call(.init(name: "submit_task", arguments: root))
    }

    var nested = submissionArguments()
    nested["execution"] = [
      "model": "gpt-5.6-sol",
      "effort": "high",
      "permission_mode": "workspaceWrite",
      "network_access": false,
      "shell": "/bin/zsh",
    ]
    await assertInvalidParams {
      _ = try await dispatcher.call(.init(name: "submit_task", arguments: nested))
    }

    var contract = try! XCTUnwrap(submissionArguments()["contract"]?.objectValue)
    contract["private_root"] = "/Volumes/private"
    var nestedContract = submissionArguments()
    nestedContract["contract"] = .object(contract)
    await assertInvalidParams {
      _ = try await dispatcher.call(.init(name: "submit_task", arguments: nestedContract))
    }
  }

  func testAbsoluteAndTraversalContractPathsAreRejected() async {
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: RecordingTaskOperations()
    )

    for path in ["/Volumes/private", "../outside", "Sources/../outside", "~/secret"] {
      var arguments = submissionArguments()
      var contract = try! XCTUnwrap(arguments["contract"]?.objectValue)
      contract["allowed_paths"] = [Value.string(path)]
      arguments["contract"] = .object(contract)
      await assertInvalidParams {
        _ = try await dispatcher.call(.init(name: "submit_task", arguments: arguments))
      }
    }
  }

  func testTaskWritesShareAdmissionAndThirdConcurrentCallIsBusy() async throws {
    let operations = RecordingTaskOperations(blocksSubmissions: true)
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations
    )
    let firstArguments = submissionArguments()
    let secondArguments = submissionArguments(key: "second")
    let first = Task {
      try await dispatcher.call(
        .init(name: "submit_task", arguments: firstArguments),
        sessionID: "same"
      )
    }
    let second = Task {
      try await dispatcher.call(
        .init(name: "submit_task", arguments: secondArguments),
        sessionID: "same"
      )
    }
    let started = try await waitUntil { await operations.submitCount == 2 }
    XCTAssertTrue(started)

    let third = try await dispatcher.call(
      .init(name: "interrupt_task", arguments: ["task_id": "tsk_1"]),
      sessionID: "same"
    )
    XCTAssertEqual(try object(third)["error"]?.objectValue?["code"], "busy")

    await operations.releaseSubmissions()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult.isError, false)
    XCTAssertEqual(secondResult.isError, false)
  }

  func testSubmitReturnsAtItsSecondaryDeadlineWithoutWaitingForBackend() async throws {
    let operations = RecordingTaskOperations(blocksSubmissions: true)
    let short = ContinuousClock.Duration.milliseconds(20)
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations,
      taskDeadlines: MCPTaskToolDeadlines(read: short, submit: short, mutation: short)
    )
    let startedAt = ContinuousClock().now

    let result = try await dispatcher.call(
      .init(name: "submit_task", arguments: submissionArguments())
    )
    let elapsed = startedAt.duration(to: ContinuousClock().now)
    await operations.releaseSubmissions()

    XCTAssertEqual(try object(result)["error"]?.objectValue?["code"], "timeout")
    XCTAssertLessThan(elapsed, .milliseconds(100))
  }

  func testTaskResultsUseTheSameTwoHundredKiBLimitAndDoNotLeakPaths() async throws {
    let operations = RecordingTaskOperations()
    await operations.setOversizedPatch(String(repeating: "x", count: 150_000))
    let dispatcher = MCPToolDispatcher(
      queries: TaskNoopQueries(),
      taskOperations: operations
    )

    let result = try await dispatcher.call(
      .init(
        name: "get_task_diff",
        arguments: ["task_id": "tsk_1", "include_patch": true]
      )
    )
    let resultObject = try object(result)
    XCTAssertEqual(resultObject["error"]?.objectValue?["code"], "result_too_large")
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(result).count,
      MCPToolResultEncoder.productionMaximumBytes
    )

    await operations.setAbsoluteDiffPath("/Volumes/private/repository/file.swift")
    do {
      _ = try await dispatcher.call(
        .init(name: "get_task_diff", arguments: ["task_id": "tsk_1"])
      )
      XCTFail("Expected invalid adapter output to fail closed.")
    } catch let error as MCPError {
      guard case .internalError(let message) = error else {
        return XCTFail("Unexpected MCP error: \(error)")
      }
      XCTAssertEqual(message, "The tool request failed.")
      XCTAssertFalse(message?.contains("/Volumes/") == true)
    }
  }

  func testMissingTaskOperationsReturnsSanitizedUnavailableError() async throws {
    let result = try await MCPToolDispatcher(queries: TaskNoopQueries()).call(
      .init(name: "get_task", arguments: ["task_id": "tsk_1"])
    )
    XCTAssertEqual(try object(result)["error"]?.objectValue?["code"], "unavailable")
    XCTAssertFalse(try text(result).contains("/Volumes/"))
  }

  private func submissionArguments(key: String = "conversation-1:message-4") -> [String: Value] {
    [
      "idempotency_key": .string(key),
      "project_id": "prj_alpha",
      "thread": ["mode": "existing", "thread_id": "thr_1"],
      "execution": [
        "model": "gpt-5.6-sol",
        "effort": "high",
        "permission_mode": "workspaceWrite",
        "network_access": false,
      ],
      "supervisor": ["enabled": true, "model": "gpt-5.6-luna", "effort": "medium"],
      "contract": [
        "goal": "Implement task tools",
        "background": "Use the existing event source.",
        "requirements": ["Keep compatibility"],
        "acceptance_criteria": ["Tests pass"],
        "non_goals": ["Remote approvals"],
        "constraints": ["No shell tool"],
        "allowed_paths": ["Packages/BridgeCore"],
        "forbidden_paths": ["Secrets"],
        "verification": ["swift test"],
      ],
    ]
  }

  private func object(_ result: CallTool.Result) throws -> [String: Value] {
    let structured = try XCTUnwrap(result.structuredContent)
    XCTAssertEqual(structured, try JSONDecoder().decode(Value.self, from: Data(text(result).utf8)))
    return try XCTUnwrap(structured.objectValue)
  }

  private func text(_ result: CallTool.Result) throws -> String {
    guard case .text(let value, _, _)? = result.content.first else {
      throw TaskToolTestError.missingText
    }
    return value
  }

  private func assertInvalidParams(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected invalid params.", file: file, line: line)
    } catch let error as MCPError {
      guard case .invalidParams = error else {
        return XCTFail("Unexpected MCP error: \(error)", file: file, line: line)
      }
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async throws -> Bool {
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while ContinuousClock().now < deadline {
      if await predicate() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private enum TaskToolTestError: Error {
  case missingText
}

private actor RecordingTaskOperations: BridgeMCPTaskOperations {
  struct EventRequest: Equatable {
    let taskID: String
    let afterSequence: Int64?
    let limit: Int
  }

  struct DiffRequest: Equatable {
    let cursor: String?
    let includePatch: Bool
  }

  struct SteerRequest: Equatable {
    let expectedTurnID: String
    let input: String
  }

  let blocksSubmissions: Bool
  private(set) var submitCount = 0
  private(set) var lastSubmission: TaskSubmission?
  private(set) var lastEventRequest: EventRequest?
  private(set) var lastDiffRequest: DiffRequest?
  private(set) var lastSteerRequest: SteerRequest?
  private var submitWaiters: [CheckedContinuation<Void, Never>] = []
  private var oversizedPatch: String?
  private var absoluteDiffPath: String?

  init(blocksSubmissions: Bool = false) {
    self.blocksSubmissions = blocksSubmissions
  }

  func setOversizedPatch(_ patch: String?) {
    oversizedPatch = patch
  }

  func setAbsoluteDiffPath(_ path: String?) {
    oversizedPatch = nil
    absoluteDiffPath = path
  }

  func releaseSubmissions() {
    let waiters = submitWaiters
    submitWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  func getTask(taskID: String, deadline: ContinuousClock.Instant) async throws -> MCPTaskSnapshot {
    MCPTaskSnapshot(
      taskID: taskID,
      phase: "running",
      activity: "idle",
      threadID: "thr_1",
      turnID: "turn_9",
      currentPlan: ["Implement", "Verify"],
      currentStep: "Verify",
      supervisorState: "ready",
      changedFileCount: 1,
      finalReportAvailable: false
    )
  }

  func getTaskEvents(
    taskID: String,
    afterSequence: Int64?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskEventPage {
    lastEventRequest = EventRequest(
      taskID: taskID,
      afterSequence: afterSequence,
      limit: limit
    )
    let first = (afterSequence ?? 0) + 1
    return MCPTaskEventPage(
      taskID: taskID,
      events: [
        MCPTaskEvent(sequence: first, kind: "turn_started"),
        MCPTaskEvent(sequence: first + 1, kind: "item_completed"),
      ],
      nextAfterSequence: first + 1
    )
  }

  func getTaskDiff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage {
    lastDiffRequest = DiffRequest(cursor: cursor, includePatch: includePatch)
    return MCPTaskDiffPage(
      taskID: taskID,
      files: [
        MCPTaskDiffFile(relativePath: absoluteDiffPath ?? "a.swift", status: "modified")
      ],
      diffStat: "1 file changed",
      patch: includePatch ? (oversizedPatch ?? "@@ bounded patch @@") : nil,
      baselineWasDirty: false
    )
  }

  func getFinalReport(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFinalReport {
    MCPFinalReport(
      taskID: taskID,
      status: "completed",
      projectName: "Codex Bridge",
      executionModel: "gpt-5.6-sol",
      executionEffort: "high",
      summary: "Implemented task tools.",
      changedFiles: ["a.swift"],
      diffStat: "1 file changed",
      verification: ["tests passed"],
      startedAt: "2026-08-12T12:00:00Z",
      completedAt: "2026-08-12T12:01:00Z"
    )
  }

  func submitTask(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt {
    submitCount += 1
    lastSubmission = submission
    if blocksSubmissions {
      await withCheckedContinuation { submitWaiters.append($0) }
    }
    return MCPTaskSubmissionReceipt(
      taskID: "tsk_1",
      phase: "awaitingLocalApproval",
      reusedExistingTask: submitCount > 1,
      localApprovalRequired: true
    )
  }

  func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    lastSteerRequest = SteerRequest(expectedTurnID: expectedTurnID, input: input)
    return MCPTaskMutationReceipt(
      taskID: taskID,
      phase: "running",
      accepted: true,
      operationID: "op_steer"
    )
  }

  func interruptTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    MCPTaskMutationReceipt(
      taskID: taskID,
      phase: "running",
      accepted: true,
      operationID: "op_interrupt"
    )
  }
}

private struct TaskNoopQueries: BridgeMCPQueries {
  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "0.1.0",
      mcpState: "ready",
      tunnelState: "connected",
      executionState: "ready",
      supervisorState: "ready",
      pendingApprovalCount: 0
    )
  }

  func listMCPVisibleProjects(
    cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage { MCPProjectPage(projects: []) }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage { MCPThreadPage(threads: []) }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage { throw BridgeMCPQueryError.threadNotFound }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    MCPModelList(models: [])
  }
}
