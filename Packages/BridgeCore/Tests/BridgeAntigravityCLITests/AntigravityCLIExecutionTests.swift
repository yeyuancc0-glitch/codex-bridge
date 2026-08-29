import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIExecutionTests: XCTestCase {
  func testQueuesSteerUntilTheCurrentResultThenCompletesTheSameSession() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-execution")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    await transport.setHandler { frame, transport in
      let message = try JSONDecoder().decode(AntigravityUserMessage.self, from: frame)
      let sent = await transport.sentFramesValue()
      guard sent.count == 2 else {
        XCTAssertEqual(message.message.content, "Inspect the repository.")
        return
      }
      XCTAssertEqual(message.message.content, "Follow up on the findings.")
      try await transport.emit(
        AntigravityCLITestSupport.resultFrame(response: "Follow-up complete.")
      )
    }
    let execution = AntigravityCLIExecution(
      taskID: TaskID(rawValue: "task-agy-steer"),
      installationID: AgentInstallationID(rawValue: "agy-test"),
      projectRoot: projectRoot,
      requestedSessionID: nil,
      prompt: "Inspect the repository.",
      runID: "run-steer",
      transport: transport,
      inactivityTimeout: .seconds(5),
      cleanup: {}
    )

    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    let binding = try await execution.waitForBinding(timeout: .seconds(1))
    XCTAssertEqual(binding.providerID, .antigravity)
    XCTAssertEqual(binding.providerSessionID, "conversation-1")
    XCTAssertEqual(binding.providerRunID, "run-steer")
    try await execution.steer(text: "  Follow up on the findings.  ")

    let eventsTask = Task { () -> [AgentEventEnvelope] in
      var events: [AgentEventEnvelope] = []
      do {
        for try await event in execution.events {
          events.append(event)
        }
      } catch {
        XCTFail("Unexpected execution stream error: \(error)")
      }
      return events
    }
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "Initial pass complete.")
    )
    let events = await eventsTask.value
    let sentFrames = await transport.sentFramesValue()
    let sentMessages = try sentFrames.map {
      try JSONDecoder().decode(AntigravityUserMessage.self, from: $0).message.content
    }
    XCTAssertEqual(
      sentMessages,
      ["Inspect the repository.", "Follow up on the findings."]
    )
    XCTAssertEqual(events.count, 3)
    guard case .content(let firstContent) = events[0].event,
      case .content(let secondContent) = events[1].event,
      case .completed(let summary, let stopReason) = events[2].event
    else {
      return XCTFail("Expected two result contents and one terminal completion")
    }
    XCTAssertEqual(firstContent.content, "Initial pass complete.")
    XCTAssertEqual(secondContent.content, "Follow-up complete.")
    XCTAssertEqual(summary, "Follow-up complete.")
    XCTAssertEqual(stopReason, "SUCCESS")
    XCTAssertEqual(events.map(\.providerSequence), [0, 1, 2])
  }

  func testSoftDeniedSuccessProducesFailureAndNoCompletion() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-denial")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport(
      standardError: BoundedProcessOutput(
        head: "",
        tail: "tool permission denied in headless mode",
        byteCount: 39,
        truncated: false
      )
    )
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)

    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "The tool was not run.")
    )
    let events = await eventsTask.value
    XCTAssertEqual(events.count, 3)
    guard case .content(let content) = events[0].event,
      case .approvalAutomaticallyDenied(let reason) = events[1].event,
      case .failed(let code, _) = events[2].event
    else {
      return XCTFail("Expected content, denial, and failure events")
    }
    XCTAssertEqual(reason, "antigravity-soft-denial")
    XCTAssertEqual(code, "antigravity_permission_denied")
    XCTAssertEqual(content.content, "The tool was not run.")
  }

  func testStructuredToolDenialIsRememberedUntilResult() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-structured-denial")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    let denial = AntigravityCLITestSupport.stepUpdateFrame(
      stepIndex: 1,
      state: "DONE",
      stepType: "tool",
      textDelta: nil,
      toolName: "run_command",
      toolInfo:
        "{\"name\":\"run_command\",\"parameters\":{\"command\":\"touch output\"},\"output\":null,\"error\":{\"type\":\"permission\",\"message\":\"permission denied by headless mode\"}}"
    )
    try await transport.emit(denial)
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "The command was skipped.")
    )

    let events = await eventsTask.value
    XCTAssertEqual(events.count, 4)
    guard case .tool(let tool) = events[0].event,
      case .content = events[1].event,
      case .approvalAutomaticallyDenied = events[2].event,
      case .failed(let code, _) = events[3].event
    else {
      return XCTFail("Expected tool, result content, denial, and failure")
    }
    XCTAssertEqual(tool.status, .failed)
    XCTAssertEqual(code, "antigravity_permission_denied")
  }

  func testAgyErrorStatePermissionDenialFailsInsteadOfProtocolViolation() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-error-state-denial")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    try await transport.emit(
      AntigravityCLITestSupport.data(
        """
        {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":4,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"twitter search Tibo"}},"error":{"type":"TOOL_ERROR","message":"permission check failed: user denied permission to run command"}}}
        """
      )
    )
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "The command was skipped.")
    )

    let events = await eventsTask.value
    guard case .tool(let tool) = events.first?.event,
      case .failed(let code, _) = events.last?.event
    else {
      return XCTFail("Expected failed tool and permission-denied terminal event")
    }
    XCTAssertEqual(tool.status, .failed)
    XCTAssertEqual(code, "antigravity_permission_denied")
    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
  }

  func testTopLevelPermissionDenialIsNotHiddenByToolInfoError() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-dual-error-denial")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    try await transport.emit(
      AntigravityCLITestSupport.data(
        """
        {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":4,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"status"},"error":{"type":"TOOL_ERROR","message":"command failed"}},"error":{"type":"PERMISSION","message":"headless mode cannot prompt; operation was auto-denied"}}}
        """
      )
    )
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "The command was skipped.")
    )

    let events = await eventsTask.value
    guard case .failed(let code, let summary) = events.last?.event else {
      return XCTFail("Expected a permission-denied terminal event")
    }
    XCTAssertEqual(code, "antigravity_permission_denied")
    XCTAssertTrue(summary.contains("Tool Execution Policy 'proceed-in-sandbox'"))
  }

  func testImmediatelyFollowingAnonymousDenialRetainsFailedWebToolClassification() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-web-denial")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(
        cwd: projectRoot,
        permissionMode: "proceed-in-sandbox"
      )
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    try await transport.emit(
      AntigravityCLITestSupport.data(
        """
        {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":4,"state":"DONE","step_type":"tool","tool_name":"read_url_content","tool_info":{"name":"read_url_content","parameters":{"url":"https://example.com"},"error":{"type":"TOOL_ERROR","message":"request failed"}}}}
        """
      )
    )
    try await transport.emit(
      AntigravityCLITestSupport.data(
        """
        {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":5,"state":"ERROR","step_type":"tool","tool_name":null,"error":{"type":"PERMISSION","message":"The requested operation was denied by local policy."}}}
        """
      )
    )
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(
        status: "SUCCESS",
        response: "The page could not be read."
      )
    )

    let events = await eventsTask.value
    XCTAssertEqual(events.map(\.providerSequence), [0, 1, 2, 3, 4])
    guard case .tool(let webTool) = events[0].event,
      case .tool(let denialTool) = events[1].event,
      case .content(let content) = events[2].event,
      case .approvalAutomaticallyDenied = events[3].event,
      case .failed(let code, let summary) = events[4].event
    else {
      return XCTFail("Expected failed web tool, denial, response, and terminal failure")
    }
    XCTAssertEqual(webTool.name, "read_url_content")
    XCTAssertEqual(webTool.status, .failed)
    XCTAssertEqual(webTool.output, "request failed")
    XCTAssertEqual(denialTool.status, .failed)
    XCTAssertEqual(content.content, "The page could not be read.")
    XCTAssertEqual(code, "antigravity_permission_denied")
    XCTAssertTrue(summary.contains("native tool 'read_url_content'"))
    XCTAssertTrue(summary.contains("Internet Access Policy"))
    XCTAssertFalse(events.contains { if case .completed = $0.event { true } else { false } })
  }

  func testInterruptRequestsProviderAndEndsWithInterruptedEvent() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-interrupt")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)

    try await execution.interrupt()
    let interruptCount = await transport.interruptCountValue()
    XCTAssertEqual(interruptCount, 1)
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(status: "INTERRUPTED", response: "Partial output.")
    )
    let events = await eventsTask.value
    XCTAssertEqual(events.count, 2)
    guard case .content(let content) = events[0].event,
      case .interrupted = events[1].event
    else {
      return XCTFail("Expected partial output followed by interruption")
    }
    XCTAssertEqual(content.content, "Partial output.")
  }

  func testShutdownDuringPermissionCheckDropsLateResultAndQueuedSteer() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-shutdown-permission")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = GatedAntigravityTransport(
      blocksFirstStandardErrorSnapshot: true,
      blocksClose: true
    )
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsFinished = TestGate()
    let eventsTask = collectEvents(from: execution.events, completion: eventsFinished)
    try await execution.steer(text: "Follow up after shutdown.")

    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "The first turn completed.")
    )
    await transport.waitForFirstStandardErrorSnapshot()

    let shutdownTask = Task { await execution.shutdown() }
    await transport.waitForCloseStart()
    await transport.releaseFirstStandardErrorSnapshot()
    try await Task.sleep(for: .milliseconds(100))

    let sentFrameCount = await transport.sentFramesValue().count
    let didFinishEvents = await eventsFinished.wait(timeout: .milliseconds(100))
    XCTAssertEqual(sentFrameCount, 1)
    XCTAssertTrue(didFinishEvents)

    await transport.releaseClose()
    await shutdownTask.value
    let events = await eventsTask.value
    XCTAssertEqual(events.count, 1)
    guard case .interrupted = events[0].event else {
      return XCTFail("Expected shutdown to remain the only terminal event")
    }
  }

  func testShutdownDuringInitialSendFinishesEventsBeforeTransportClose() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-shutdown-send")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = GatedAntigravityTransport(
      blocksFirstSend: true,
      blocksClose: true
    )
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsFinished = TestGate()
    let eventsTask = collectEvents(from: execution.events, completion: eventsFinished)
    try await execution.steer(text: "Do not send after shutdown.")
    await transport.waitForFirstSend()

    let shutdownTask = Task { await execution.shutdown() }
    await transport.waitForCloseStart()
    await transport.releaseFirstSend()

    let didFinishEvents = await eventsFinished.wait(timeout: .seconds(1))
    let sentFrameCount = await transport.sentFramesValue().count
    XCTAssertTrue(didFinishEvents)
    XCTAssertEqual(sentFrameCount, 1)

    await transport.releaseClose()
    await shutdownTask.value
    let events = await eventsTask.value
    XCTAssertEqual(events.count, 1)
    guard case .interrupted = events[0].event else {
      return XCTFail("Expected shutdown to remain the only terminal event")
    }
  }

  func testInterruptDuringResultNormalizationDropsQueuedSteer() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-interrupt-normalize")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let normalizationStarted = TestGate()
    let normalizationRelease = TestGate()
    let execution = makeExecution(
      projectRoot: projectRoot,
      transport: transport,
      beforeResultNormalization: {
        normalizationStarted.release()
        await normalizationRelease.wait()
      }
    )
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    try await execution.steer(text: "Do not send this after interrupt.")

    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "Initial pass complete.")
    )
    await normalizationStarted.wait()
    let interruptTask = Task { try? await execution.interrupt() }
    await interruptTask.value
    normalizationRelease.release()

    let events = await eventsTask.value
    let sentFrames = await transport.sentFramesValue()
    XCTAssertEqual(sentFrames.count, 1)
    XCTAssertEqual(events.count, 2)
    guard case .content(let content) = events[0].event,
      case .interrupted = events[1].event
    else {
      return XCTFail("Expected result content followed by interruption")
    }
    XCTAssertEqual(content.content, "Initial pass complete.")
  }

  func testInterruptDuringQueuedSteerSendKeepsResultBoundToInterrupt() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-interrupt-send")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = GatedAntigravityTransport(blocksSecondSend: true)
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: projectRoot)
    )
    _ = try await execution.waitForBinding(timeout: .seconds(1))
    let eventsTask = collectEvents(from: execution.events)
    try await execution.steer(text: "Follow up before interruption.")

    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(response: "Initial pass complete.")
    )
    await transport.waitForSecondSend()
    let interruptTask = Task { try? await execution.interrupt() }
    await interruptTask.value
    await transport.releaseSecondSend()
    try await transport.emit(
      AntigravityCLITestSupport.resultFrame(
        status: "INTERRUPTED",
        response: "Partial follow-up output."
      )
    )

    let events = await eventsTask.value
    let sentFrames = await transport.sentFramesValue()
    XCTAssertEqual(sentFrames.count, 2)
    XCTAssertEqual(events.count, 3)
    guard case .content(let firstContent) = events[0].event,
      case .content(let secondContent) = events[1].event,
      case .interrupted = events[2].event
    else {
      return XCTFail("Expected both result contents followed by interruption")
    }
    XCTAssertEqual(firstContent.content, "Initial pass complete.")
    XCTAssertEqual(secondContent.content, "Partial follow-up output.")
  }

  func testRejectsWrongConversationBeforeCreatingBinding() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-session")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = AntigravityCLIExecution(
      taskID: TaskID(rawValue: "task-agy-session"),
      installationID: AgentInstallationID(rawValue: "agy-test"),
      projectRoot: projectRoot,
      requestedSessionID: "expected-conversation",
      prompt: "Inspect",
      transport: transport,
      inactivityTimeout: .seconds(5),
      cleanup: {}
    )
    await execution.start()
    let bindingTask = Task {
      try await execution.waitForBinding(timeout: .seconds(1))
    }
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(
        conversationID: "other-conversation",
        cwd: projectRoot
      )
    )
    do {
      _ = try await bindingTask.value
      XCTFail("Expected wrong conversation to prevent binding")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .sessionMismatch)
    }
    let sentFrames = await transport.sentFramesValue()
    XCTAssertEqual(sentFrames.count, 0)
  }

  func testRejectsWrongCwdBeforeCreatingBinding() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-cwd")
    let wrongRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-wrong-cwd")
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: wrongRoot)
    }
    let transport = ScriptedAntigravityTransport()
    let execution = makeExecution(projectRoot: projectRoot, transport: transport)
    await execution.start()
    let bindingTask = Task {
      try await execution.waitForBinding(timeout: .seconds(1))
    }
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(cwd: wrongRoot)
    )
    do {
      _ = try await bindingTask.value
      XCTFail("Expected wrong cwd to prevent binding")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .sessionMismatch)
    }
    let sentFrames = await transport.sentFramesValue()
    XCTAssertEqual(sentFrames.count, 0)
  }

  func testRejectsUnexpectedModelBeforeCreatingBinding() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-model")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let transport = ScriptedAntigravityTransport()
    let execution = AntigravityCLIExecution(
      taskID: TaskID(rawValue: "task-agy-model"),
      installationID: AgentInstallationID(rawValue: "agy-test"),
      projectRoot: projectRoot,
      requestedSessionID: nil,
      expectedModel: "gemini-pro",
      prompt: "Inspect",
      transport: transport,
      inactivityTimeout: .seconds(5),
      cleanup: {}
    )
    await execution.start()
    let bindingTask = Task {
      try await execution.waitForBinding(timeout: .seconds(1))
    }
    try await transport.emit(
      AntigravityCLITestSupport.initializationFrame(
        cwd: projectRoot,
        model: "gemini-flash"
      )
    )
    do {
      _ = try await bindingTask.value
      XCTFail("Expected wrong model to prevent binding")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .modelMismatch("gemini-pro"))
    }
    let sentFrames = await transport.sentFramesValue()
    XCTAssertEqual(sentFrames.count, 0)
  }

  private func makeExecution(
    projectRoot: String,
    transport: any AntigravityCLITransport,
    beforeResultNormalization: @escaping @Sendable () async -> Void = {}
  ) -> AntigravityCLIExecution {
    AntigravityCLIExecution(
      taskID: TaskID(rawValue: "task-agy-execution"),
      installationID: AgentInstallationID(rawValue: "agy-test"),
      projectRoot: projectRoot,
      requestedSessionID: nil,
      prompt: "Inspect the repository.",
      runID: "run-1",
      transport: transport,
      inactivityTimeout: .seconds(5),
      cleanup: {},
      beforeResultNormalization: beforeResultNormalization
    )
  }

  private func collectEvents(
    from stream: AsyncThrowingStream<AgentEventEnvelope, any Error>,
    completion: TestGate? = nil
  ) -> Task<[AgentEventEnvelope], Never> {
    Task {
      var events: [AgentEventEnvelope] = []
      defer { completion?.release() }
      do {
        for try await event in stream {
          events.append(event)
        }
      } catch {
        XCTFail("Unexpected execution stream error: \(error)")
      }
      return events
    }
  }
}

private final class TestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isReleased {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func wait(timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !released {
      guard ContinuousClock.now < deadline else { return released }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }

  func release() {
    lock.lock()
    guard !isReleased else {
      lock.unlock()
      return
    }
    isReleased = true
    let continuations = waiters
    waiters.removeAll(keepingCapacity: false)
    lock.unlock()
    for continuation in continuations { continuation.resume() }
  }

  private var released: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isReleased
  }
}

private actor GatedAntigravityTransport: AntigravityCLITransport {
  nonisolated let incoming: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let blocksFirstSend: Bool
  private let blocksSecondSend: Bool
  private let blocksFirstStandardErrorSnapshot: Bool
  private let blocksClose: Bool
  private let firstSendStarted = TestGate()
  private let firstSendRelease = TestGate()
  private let secondSendStarted = TestGate()
  private let secondSendRelease = TestGate()
  private let firstStandardErrorSnapshotStarted = TestGate()
  private let firstStandardErrorSnapshotRelease = TestGate()
  private let closeStarted = TestGate()
  private let closeRelease = TestGate()
  private var sendCount = 0
  private var standardErrorSnapshotCount = 0
  private var sentFrames: [Data] = []
  private var closed = false

  init(
    blocksFirstSend: Bool = false,
    blocksSecondSend: Bool = false,
    blocksFirstStandardErrorSnapshot: Bool = false,
    blocksClose: Bool = false
  ) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(256)
    )
    incoming = pair.stream
    continuation = pair.continuation
    self.blocksFirstSend = blocksFirstSend
    self.blocksSecondSend = blocksSecondSend
    self.blocksFirstStandardErrorSnapshot = blocksFirstStandardErrorSnapshot
    self.blocksClose = blocksClose
  }

  func send(_ frame: Data) async throws {
    guard !closed else { throw AntigravityCLIError.transportClosed }
    sendCount += 1
    sentFrames.append(frame)
    if blocksFirstSend, sendCount == 1 {
      firstSendStarted.release()
      await firstSendRelease.wait()
    }
    if blocksSecondSend, sendCount == 2 {
      secondSendStarted.release()
      await secondSendRelease.wait()
    }
  }

  func interrupt() async {}

  func standardErrorSnapshot() async -> BoundedProcessOutput {
    standardErrorSnapshotCount += 1
    if blocksFirstStandardErrorSnapshot, standardErrorSnapshotCount == 1 {
      firstStandardErrorSnapshotStarted.release()
      await firstStandardErrorSnapshotRelease.wait()
    }
    return BoundedProcessOutput(head: "", tail: "", byteCount: 0, truncated: false)
  }

  func close() async {
    guard !closed else { return }
    if blocksClose {
      closeStarted.release()
      await closeRelease.wait()
    }
    guard !closed else { return }
    closed = true
    continuation.finish()
  }

  func emit(_ frame: Data) throws {
    guard !closed else { throw AntigravityCLIError.transportClosed }
    let result = continuation.yield(frame)
    if case .dropped = result {
      closed = true
      continuation.finish(throwing: AntigravityCLIError.transportClosed)
      throw AntigravityCLIError.transportClosed
    }
  }

  func sentFramesValue() -> [Data] {
    sentFrames
  }

  func waitForFirstSend() async {
    await firstSendStarted.wait()
  }

  func releaseFirstSend() {
    firstSendRelease.release()
  }

  func waitForSecondSend() async {
    await secondSendStarted.wait()
  }

  func releaseSecondSend() {
    secondSendRelease.release()
  }

  func waitForFirstStandardErrorSnapshot() async {
    await firstStandardErrorSnapshotStarted.wait()
  }

  func releaseFirstStandardErrorSnapshot() {
    firstStandardErrorSnapshotRelease.release()
  }

  func waitForCloseStart() async {
    await closeStarted.wait()
  }

  func releaseClose() {
    closeRelease.release()
  }
}
