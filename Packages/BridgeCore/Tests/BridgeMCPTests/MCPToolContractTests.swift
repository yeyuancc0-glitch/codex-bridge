import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPToolContractTests: XCTestCase {
  func testServiceListAgentsSchemaDocumentsDeepSeekReadOnlyNetworkBoundary() throws {
    let definitions = MCPServiceToolCatalog(exposureMode: .readOnly).definitions
    let definition = try XCTUnwrap(
      definitions.first(where: { $0.name == MCPServiceToolName.listAgents.rawValue })
    )
    let agentProperties = try XCTUnwrap(
      definition.outputSchema?.objectValue?["properties"]?.objectValue?["agents"]?
        .objectValue?["items"]?
        .objectValue?["properties"]?.objectValue
    )
    let providerDescription = try XCTUnwrap(
      agentProperties["provider_id"]?.objectValue?["description"])
    let capabilityDescription = try XCTUnwrap(
      agentProperties["effective_capabilities"]?.objectValue?["description"]
    )
    let networkDescription = try XCTUnwrap(
      agentProperties["network_enforcement"]?.objectValue?["description"]
    )
    XCTAssertTrue(providerDescription.stringValue?.contains("deepseek-harness") == true)
    XCTAssertTrue(capabilityDescription.stringValue?.contains("workspace.read") == true)
    XCTAssertTrue(networkDescription.stringValue?.contains("does not guarantee") == true)

    let instructions = MCPServiceServerFactory.instructions(customInstructions: "")
    XCTAssertTrue(instructions.contains("provider_id=deepseek-harness"))
    XCTAssertTrue(instructions.contains("automatically denied"))
    XCTAssertTrue(instructions.contains("network_enforcement"))
  }

  func testCatalogPublishesStrictClosedSchemasAndAccurateAnnotations() throws {
    let definitions = MCPToolCatalog(includeTaskTools: true).definitions

    let expectedNames =
      MCPToolName.allCases.map(\.rawValue) + MCPTaskToolName.allCases.map(\.rawValue)
    XCTAssertEqual(definitions.map(\.name), expectedNames)
    for definition in definitions {
      XCTAssertEqual(definition.annotations.openWorldHint, false)
      try assertObjectSchemasAreClosed(definition.inputSchema)
      try assertObjectSchemasAreClosed(XCTUnwrap(definition.outputSchema))
      XCTAssertEqual(definition.inputSchema.objectValue?["type"], "object")
      XCTAssertEqual(definition.inputSchema.objectValue?["additionalProperties"], false)
      XCTAssertEqual(definition.outputSchema?.objectValue?["type"], "object")
      XCTAssertEqual(definition.outputSchema?.objectValue?["additionalProperties"], false)
    }

    let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    let readOnlyNames = Set([
      "bridge_status", "list_projects", "list_threads", "read_thread", "list_models",
      "get_task", "get_task_events", "get_task_diff", "get_final_report",
    ])
    for name in readOnlyNames {
      XCTAssertEqual(byName[name]?.annotations.readOnlyHint, true)
      XCTAssertEqual(byName[name]?.annotations.destructiveHint, false)
      XCTAssertEqual(byName[name]?.annotations.idempotentHint, true)
    }
    let modelItems = byName["list_models"]?.outputSchema?.objectValue?["properties"]?
      .objectValue?["models"]?.objectValue?["items"]?.objectValue
    XCTAssertNotNil(modelItems?["properties"]?.objectValue?["default_reasoning_effort"])
    XCTAssertFalse(
      modelItems?["required"]?.arrayValue?.contains(.string("default_reasoning_effort")) == true
    )
    XCTAssertEqual(byName["submit_task"]?.annotations.readOnlyHint, false)
    XCTAssertEqual(byName["submit_task"]?.annotations.destructiveHint, false)
    XCTAssertEqual(byName["submit_task"]?.annotations.idempotentHint, true)
    XCTAssertEqual(byName["steer_task"]?.annotations.readOnlyHint, false)
    XCTAssertEqual(byName["steer_task"]?.annotations.destructiveHint, false)
    XCTAssertEqual(byName["steer_task"]?.annotations.idempotentHint, false)
    XCTAssertEqual(byName["interrupt_task"]?.annotations.readOnlyHint, false)
    XCTAssertEqual(byName["interrupt_task"]?.annotations.destructiveHint, true)
    XCTAssertEqual(byName["interrupt_task"]?.annotations.idempotentHint, false)
    XCTAssertNil(byName["respond_to_codex_approval"])
  }

  func testAllReadOnlyToolsReturnLiveStateWithStructuredTextParity() async throws {
    let queries = InMemoryMCPQueries()
    let dispatcher = MCPToolDispatcher(queries: queries)

    let status = try await dispatcher.call(.init(name: "bridge_status", arguments: [:]))
    let statusObject = try resultObject(status)
    XCTAssertEqual(statusObject["schema_version"], 1)
    XCTAssertEqual(statusObject["app_version"], "0.1.0")
    XCTAssertEqual(statusObject["pending_approval_count"], 2)

    let projects = try await dispatcher.call(
      .init(name: "list_projects", arguments: ["limit": 1]))
    let projectsObject = try resultObject(projects)
    XCTAssertEqual(projectsObject["next_cursor"], "1")
    XCTAssertEqual(projectsObject["projects"]?.arrayValue?.count, 1)
    XCTAssertNil(projectsObject["projects"]?.arrayValue?.first?.objectValue?["root"])

    let threads = try await dispatcher.call(
      .init(
        name: "list_threads",
        arguments: [
          "project_id": "prj_alpha",
          "search": "Build",
          "limit": 25,
        ]
      ))
    let threadItems = try XCTUnwrap(resultObject(threads)["threads"]?.arrayValue)
    XCTAssertEqual(threadItems.count, 1)
    XCTAssertEqual(threadItems.first?.objectValue?["thread_id"], "thr_build")

    let read = try await dispatcher.call(
      .init(
        name: "read_thread",
        arguments: [
          "project_id": "prj_alpha",
          "thread_id": "thr_build",
          "detail": "full",
        ]
      ))
    let readObject = try resultObject(read)
    XCTAssertEqual(readObject["detail"], "full")
    XCTAssertEqual(readObject["entries"]?.arrayValue?.count, 2)
    XCTAssertEqual(
      readObject["entries"]?.arrayValue?.last?.objectValue?["text"],
      "Tests are green."
    )

    let models = try await dispatcher.call(.init(name: "list_models"))
    let model = try XCTUnwrap(resultObject(models)["models"]?.arrayValue?.first?.objectValue)
    XCTAssertEqual(model["model_id"], "gpt-5.6-sol")
    XCTAssertEqual(model["reasoning_efforts"]?.arrayValue, ["low", "high"])
    XCTAssertEqual(model["default_reasoning_effort"], "high")
  }

  func testUnknownAndMalformedArgumentsAreInvalidParams() async {
    let dispatcher = MCPToolDispatcher(queries: InMemoryMCPQueries())

    await assertInvalidParams {
      _ = try await dispatcher.call(.init(name: "not_a_tool"))
    }
    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(name: "bridge_status", arguments: ["unexpected": true]))
    }
    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(name: "list_projects", arguments: ["limit": 101]))
    }
    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(
          name: "list_threads",
          arguments: [
            "project_id": "prj_alpha",
            "search": .string(String(repeating: "界", count: 67)),
          ]
        ))
    }
    await assertInvalidParams {
      _ = try await dispatcher.call(
        .init(
          name: "read_thread",
          arguments: ["project_id": "prj_alpha", "thread_id": "thr_build", "detail": "raw"]
        ))
    }
  }

  func testExpectedDomainFailureIsStructuredAndDoesNotLeakInternalText() async throws {
    let queries = InMemoryMCPQueries()
    await queries.setFailure(.projectNotFound)
    let dispatcher = MCPToolDispatcher(queries: queries)

    let result = try await dispatcher.call(
      .init(name: "list_threads", arguments: ["project_id": "prj_missing"]))
    let object = try resultObject(result)

    XCTAssertEqual(result.isError, true)
    XCTAssertEqual(object["schema_version"], 1)
    XCTAssertEqual(object["error"]?.objectValue?["code"], "project_not_found")
    XCTAssertEqual(object["error"]?.objectValue?["retryable"], false)
    XCTAssertFalse(try resultText(result).contains("/Volumes/"))
  }

  func testEveryExpectedQueryErrorUsesBoundedStructuredContract() async throws {
    let cases: [(BridgeMCPQueryError, String, Bool)] = [
      (.projectNotFound, "project_not_found", false),
      (.threadNotFound, "thread_not_found", false),
      (.pathDenied, "path_denied", false),
      (.taskNotFound, "task_not_found", false),
      (.idempotencyConflict, "idempotency_conflict", false),
      (.turnMismatch, "turn_mismatch", false),
      (.invalidTaskState, "invalid_task_state", false),
      (.contractRejected, "contract_rejected", false),
      (.busy, "busy", true),
      (.timeout, "timeout", true),
      (.unavailable, "unavailable", true),
      (.skillNotFound, "skill_not_found", false),
      (.skillActionNotFound, "skill_action_not_found", false),
      (.skillActionNotRunnable, "skill_action_not_runnable", false),
    ]

    for (failure, expectedCode, retryable) in cases {
      let queries = InMemoryMCPQueries()
      await queries.setFailure(failure)
      let result = try await MCPToolDispatcher(queries: queries).call(
        .init(name: "bridge_status"))
      let object = try resultObject(result)

      XCTAssertEqual(result.isError, true)
      XCTAssertEqual(object["error"]?.objectValue?["code"], .string(expectedCode))
      XCTAssertEqual(object["error"]?.objectValue?["retryable"], .bool(retryable))
      XCTAssertLessThanOrEqual(
        try JSONEncoder().encode(result).count,
        MCPToolResultEncoder.productionMaximumBytes
      )
    }
  }

  func testModelSummaryDecodesLegacyPayloadWithoutDefaultEffort() throws {
    let data = Data(
      #"""
      {"model_id":"legacy","display_name":"Legacy","is_default":false,"reasoning_efforts":["medium"]}
      """#.utf8
    )
    let model = try JSONDecoder().decode(MCPModelSummary.self, from: data)

    XCTAssertNil(model.defaultReasoningEffort)
    let encoded = try JSONEncoder().encode(model)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("default_reasoning_effort"))
  }

  func testUnexpectedQueryErrorBecomesGenericInternalError() async {
    let queries = InMemoryMCPQueries()
    await queries.setUnexpectedFailure(true)
    let dispatcher = MCPToolDispatcher(queries: queries)

    do {
      _ = try await dispatcher.call(.init(name: "bridge_status"))
      XCTFail("Expected MCPError.internalError.")
    } catch let error as MCPError {
      guard case .internalError(let detail) = error else {
        return XCTFail("Unexpected MCP error: \(error)")
      }
      XCTAssertEqual(detail, "The tool request failed.")
      XCTAssertFalse(detail?.contains("private-project-path") == true)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCompleteDualFormResultHasHardTwoHundredKiBLimit() async throws {
    let queries = InMemoryMCPQueries()
    await queries.setLargeThreadText(String(repeating: "x", count: 150_000))
    let dispatcher = MCPToolDispatcher(queries: queries)

    let result = try await dispatcher.call(
      .init(
        name: "read_thread",
        arguments: [
          "project_id": "prj_alpha",
          "thread_id": "thr_build",
          "detail": "full",
        ]
      ))
    let object = try resultObject(result)

    XCTAssertEqual(result.isError, true)
    XCTAssertEqual(object["error"]?.objectValue?["code"], "result_too_large")
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(result).count,
      MCPToolResultEncoder.productionMaximumBytes
    )
  }

  func testLargeMutationReceiptCanFallBackToCompactTransportForm() throws {
    let oversizedLine = String(repeating: "x", count: 150_000)
    let receipt = MCPDirectWriteReceipt(
      relativePath: "large.txt",
      operation: "replace",
      oldSHA256: String(repeating: "a", count: 64),
      newSHA256: String(repeating: "b", count: 64),
      byteCount: oversizedLine.utf8.count,
      boundedDiff: MCPBoundedDiff(
        removedLines: [],
        addedLines: [oversizedLine],
        truncated: false,
        byteCount: oversizedLine.utf8.count
      )
    )
    let encoder = MCPToolResultEncoder()

    XCTAssertThrowsError(
      try encoder.encode(ServiceDirectMutationOutput(receipt: receipt))
    )

    let compact = receipt.compactedForTransport()
    let result = try encoder.encode(ServiceDirectMutationOutput(receipt: compact))

    XCTAssertTrue(compact.boundedDiff.truncated)
    XCTAssertTrue(compact.boundedDiff.addedLines.isEmpty)
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(result).count,
      MCPToolResultEncoder.productionMaximumBytes
    )
  }

  func testAdmissionEnforcesGlobalAndPerSessionLimits() async {
    let perSession = MCPToolAdmission()
    let firstSessionPermit = await perSession.acquire(sessionID: "session-a")
    let secondSessionPermit = await perSession.acquire(sessionID: "session-a")
    let rejectedSessionPermit = await perSession.acquire(sessionID: "session-a")
    XCTAssertTrue(firstSessionPermit)
    XCTAssertTrue(secondSessionPermit)
    XCTAssertFalse(rejectedSessionPermit)
    await perSession.release(sessionID: "session-a")
    let reacquiredSessionPermit = await perSession.acquire(sessionID: "session-a")
    XCTAssertTrue(reacquiredSessionPermit)

    let global = MCPToolAdmission()
    for index in 0..<8 {
      let acquired = await global.acquire(sessionID: "session-\(index)")
      XCTAssertTrue(acquired)
    }
    let rejectedGlobalPermit = await global.acquire(sessionID: "session-overflow")
    XCTAssertFalse(rejectedGlobalPermit)
    await global.release(sessionID: "session-0")
    let reacquiredGlobalPermit = await global.acquire(sessionID: "session-after-release")
    XCTAssertTrue(reacquiredGlobalPermit)
  }

  func testDispatcherReturnsBusyForThirdConcurrentCallInOneSession() async throws {
    let queries = BlockingMCPQueries()
    let dispatcher = MCPToolDispatcher(queries: queries)
    let first = Task {
      try await dispatcher.call(.init(name: "bridge_status"), sessionID: "same-session")
    }
    let second = Task {
      try await dispatcher.call(.init(name: "bridge_status"), sessionID: "same-session")
    }

    for _ in 0..<1_000 {
      if await queries.startedCount >= 2 { break }
      await Task.yield()
    }
    let startedCount = await queries.startedCount
    XCTAssertEqual(startedCount, 2)

    let third = try await dispatcher.call(
      .init(name: "bridge_status"),
      sessionID: "same-session"
    )
    XCTAssertEqual(try resultObject(third)["error"]?.objectValue?["code"], "busy")

    await queries.releaseAll()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult.isError, false)
    XCTAssertEqual(secondResult.isError, false)
  }

  func testSecondaryTimeoutReturnsWithoutWaitingForNonCooperativeQuery() async throws {
    let short = ContinuousClock.Duration.milliseconds(20)
    let deadlines = MCPToolDeadlines(
      bridgeStatus: short,
      listProjects: short,
      listThreads: short,
      readThreadSummary: short,
      readThreadFull: short,
      listModels: short
    )
    let dispatcher = MCPToolDispatcher(
      queries: NonCooperativeMCPQueries(),
      deadlines: deadlines
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = try await dispatcher.call(.init(name: "bridge_status"))
    let elapsed = startedAt.duration(to: clock.now)

    XCTAssertEqual(result.isError, true)
    XCTAssertEqual(try resultObject(result)["error"]?.objectValue?["code"], "timeout")
    XCTAssertLessThan(elapsed, .milliseconds(100))
  }

  private func resultObject(_ result: CallTool.Result) throws -> [String: Value] {
    let structured = try XCTUnwrap(result.structuredContent)
    let textValue = try JSONDecoder().decode(Value.self, from: Data(resultText(result).utf8))
    XCTAssertEqual(textValue, structured)
    return try XCTUnwrap(structured.objectValue)
  }

  private func resultText(_ result: CallTool.Result) throws -> String {
    guard case .text(let text, _, _)? = result.content.first else {
      throw TestError.missingTextResult
    }
    return text
  }

  private func assertObjectSchemasAreClosed(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    switch value {
    case .array(let values):
      for child in values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    case .object(let object):
      if object["type"] == "object" {
        XCTAssertEqual(object["additionalProperties"], false, file: file, line: line)
      }
      for child in object.values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    default:
      break
    }
  }

  private func assertInvalidParams(
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected MCPError.invalidParams.", file: file, line: line)
    } catch let error as MCPError {
      guard case .invalidParams = error else {
        return XCTFail("Unexpected MCP error: \(error)", file: file, line: line)
      }
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private enum TestError: Error {
  case missingTextResult
}

private actor InMemoryMCPQueries: BridgeMCPQueries {
  private let projects = [
    MCPProjectSummary(
      projectID: "prj_alpha",
      name: "Codex Bridge",
      capabilities: .init(read: "allowed", write: "requiresLocalApproval", network: "denied"),
      gitState: "clean"
    ),
    MCPProjectSummary(
      projectID: "prj_beta",
      name: "Second Project",
      capabilities: .init(read: "allowed", write: "denied", network: "denied")
    ),
  ]
  private let threads = [
    MCPThreadSummary(
      threadID: "thr_build",
      title: "Build connector",
      status: "completed",
      updatedAt: "2026-08-12T12:00:00Z",
      preview: "Build the connector"
    ),
    MCPThreadSummary(threadID: "thr_review", title: "Review", status: "idle"),
  ]
  private var failure: BridgeMCPQueryError?
  private var largeThreadText: String?
  private var unexpectedFailure = false

  func setFailure(_ failure: BridgeMCPQueryError?) {
    self.failure = failure
  }

  func setLargeThreadText(_ text: String?) {
    largeThreadText = text
  }

  func setUnexpectedFailure(_ enabled: Bool) {
    unexpectedFailure = enabled
  }

  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    try failIfNeeded()
    return BridgeStatusSnapshot(
      appVersion: "0.1.0",
      mcpState: "ready",
      tunnelState: "disconnected",
      codexVersion: "0.147.0-alpha.6.5",
      loginMode: "chatgpt",
      executionState: "ready",
      supervisorState: "ready",
      degradations: ["tunnel_disconnected"],
      pendingApprovalCount: 2
    )
  }

  func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    try failIfNeeded()
    let page = page(projects, cursor: cursor, limit: limit)
    return MCPProjectPage(projects: page.values, nextCursor: page.nextCursor)
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    try failIfNeeded()
    guard projectID == "prj_alpha" else { throw BridgeMCPQueryError.projectNotFound }
    let matching = threads.filter { thread in
      guard let search else { return true }
      return thread.title?.localizedCaseInsensitiveContains(search) == true
        || thread.preview?.localizedCaseInsensitiveContains(search) == true
    }
    let page = page(matching, cursor: cursor, limit: limit)
    return MCPThreadPage(threads: page.values, nextCursor: page.nextCursor)
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    try failIfNeeded()
    guard projectID == "prj_alpha" else { throw BridgeMCPQueryError.projectNotFound }
    guard let thread = threads.first(where: { $0.threadID == threadID }) else {
      throw BridgeMCPQueryError.threadNotFound
    }
    let entries = [
      MCPThreadEntry(turnID: "turn_1", role: "user", text: "Build it."),
      MCPThreadEntry(
        turnID: "turn_1",
        role: "assistant",
        text: largeThreadText ?? "Tests are green.",
        status: "completed"
      ),
    ]
    let visibleEntries = detail == .full ? entries : []
    let result = page(visibleEntries, cursor: cursor, limit: limit)
    return MCPThreadReadPage(
      thread: thread,
      detail: detail,
      entries: result.values,
      nextCursor: result.nextCursor
    )
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    try failIfNeeded()
    return MCPModelList(
      models: [
        MCPModelSummary(
          modelID: "gpt-5.6-sol",
          displayName: "GPT-5.6 Sol",
          isDefault: true,
          reasoningEfforts: ["low", "high"],
          defaultReasoningEffort: "high"
        )
      ]
    )
  }

  private func failIfNeeded() throws {
    if unexpectedFailure {
      throw TestInternalFailure(message: "private-project-path")
    }
    if let failure {
      throw failure
    }
  }

  private func page<Element>(
    _ values: [Element],
    cursor: String?,
    limit: Int
  ) -> (values: [Element], nextCursor: String?) {
    let start = cursor.flatMap(Int.init) ?? 0
    let safeStart = min(start, values.count)
    let end = min(safeStart + limit, values.count)
    let nextCursor = end < values.count ? String(end) : nil
    return (Array(values[safeStart..<end]), nextCursor)
  }
}

private struct TestInternalFailure: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

private actor BlockingMCPQueries: BridgeMCPQueries {
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var startedCount: Int { waiters.count }

  func releaseAll() {
    let waiters = waiters
    self.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
    return makeReadyStatus()
  }

  func listMCPVisibleProjects(
    cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    throw BridgeMCPQueryError.unavailable
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    throw BridgeMCPQueryError.unavailable
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    throw BridgeMCPQueryError.unavailable
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    throw BridgeMCPQueryError.unavailable
  }
}

private struct NonCooperativeMCPQueries: BridgeMCPQueries {
  func statusSnapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
        continuation.resume()
      }
    }
    return makeReadyStatus()
  }

  func listMCPVisibleProjects(
    cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    throw BridgeMCPQueryError.unavailable
  }

  func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    throw BridgeMCPQueryError.unavailable
  }

  func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    throw BridgeMCPQueryError.unavailable
  }

  func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    throw BridgeMCPQueryError.unavailable
  }
}

private func makeReadyStatus() -> BridgeStatusSnapshot {
  BridgeStatusSnapshot(
    appVersion: "0.1.0",
    mcpState: "ready",
    tunnelState: "connected",
    executionState: "ready",
    supervisorState: "ready",
    pendingApprovalCount: 0
  )
}
