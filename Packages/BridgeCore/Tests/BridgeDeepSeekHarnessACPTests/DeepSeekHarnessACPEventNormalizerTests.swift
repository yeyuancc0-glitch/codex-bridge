import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import XCTest

@testable import BridgeCodexService
@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPEventNormalizerTests: XCTestCase {
  func testFinalResponseAfterToolIsOrderedAfterToolInSQLite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-dsh-order-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SimpleServiceStore(path: root.appending(path: "service.sqlite").path)
    let projectID = ProjectID(rawValue: "dsh-order-project")
    let projects = ServiceProjectService(
      store: store,
      makeProjectID: { projectID }
    )
    let project = try await projects.register(
      name: "DSH order fixture",
      rootURL: root,
      id: projectID
    )
    let tasks = ServiceTaskManager(
      store: store,
      makeTaskID: { TaskID(rawValue: "dsh-order-task") }
    )
    let created = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Run the fixture.",
        providerID: DeepSeekHarnessACPConstants.providerID.rawValue,
        installationID: "dsh-installation",
        selectionMode: .explicit,
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .readOnly
      ),
      taskID: TaskID(rawValue: "dsh-order-task")
    )
    let task = try await tasks.begin(taskID: created.task.id)
    let conversation = TaskConversationBuffer(
      tasks: tasks,
      flushDeltaCount: 1,
      flushInFlightCount: 1
    )
    let processor = ServiceExecutionAgentEventProcessor(
      tasks: tasks,
      projects: projects,
      conversation: conversation
    )
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "dsh-installation"),
      providerSessionID: "dsh-session",
      providerRunID: "dsh-run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: task.id,
      binding: binding
    )

    let preamble = try await normalizer.normalizeForExecution(
      .init(sequence: 0, event: .textDelta(sessionID: "dsh-session", text: "先检查环境。"))
    )
    let started = try await normalizer.normalizeForExecution(
      .init(
        sequence: 1,
        event: .toolUpdated(
          .init(
            sessionID: "dsh-session",
            toolCallID: "shell-1",
            title: "bash",
            kind: "bash",
            status: .inProgress,
            rawInput: .object(["command": .string("echo ok")])
          )
        )
      )
    )
    let completed = try await normalizer.normalizeForExecution(
      .init(
        sequence: 2,
        event: .toolUpdated(
          .init(
            sessionID: "dsh-session",
            toolCallID: "shell-1",
            title: nil,
            kind: nil,
            status: .completed,
            rawInput: nil
          )
        )
      )
    )
    let response = try await normalizer.normalizeForExecution(
      .init(sequence: 3, event: .textDelta(sessionID: "dsh-session", text: "最终结果。"))
    )
    let final = try await normalizer.finalizeContent()
    XCTAssertEqual(preamble.map(\.providerSequence), [0])
    XCTAssertEqual(started.map(\.providerSequence), [1, 2])
    XCTAssertEqual(completed.map(\.providerSequence), [3])
    XCTAssertEqual(response.map(\.providerSequence), [4])
    XCTAssertEqual(final.map(\.providerSequence), [5])
    for event in [preamble, started, completed, response].flatMap({ $0 }) + final {
      try await processor.process(event.event, taskID: task.id)
    }
    let closed = await conversation.close(taskID: task.id)
    XCTAssertTrue(closed)

    let messages = try await store.taskMessages(taskID: task.id)
    XCTAssertEqual(
      messages.map(\.key),
      ["agent:message:assistant", "tool:shell-1", "agent:message:assistant:1"]
    )
    XCTAssertEqual(messages.last?.content, "最终结果。")
  }

  func testFinalContentIsAuthoritativeAfterOrderedDeltas() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding
    )
    let first = try await normalizer.normalize(
      .init(sequence: 0, event: .textDelta(sessionID: "session", text: "A"))
    )
    let second = try await normalizer.normalize(
      .init(sequence: 1, event: .textDelta(sessionID: "session", text: "B"))
    )
    let final = try await normalizer.finalizeContent()
    XCTAssertEqual(first?.providerSequence, 0)
    XCTAssertEqual(second?.providerSequence, 1)
    XCTAssertEqual(final.first?.providerSequence, 2)
    guard case .content(let update) = final.first?.event else {
      return XCTFail("Expected authoritative content")
    }
    XCTAssertEqual(update.mode, .full)
    XCTAssertEqual(update.content, "AB")
    XCTAssertTrue(update.isFinal)
    XCTAssertTrue(update.authoritative)
  }

  func testMismatchedSessionIsRejected() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding
    )
    do {
      _ = try await normalizer.normalize(
        .init(sequence: 0, event: .textDelta(sessionID: "other", text: "bad"))
      )
      XCTFail("Expected a session mismatch")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .sessionMismatch)
    }
  }

  func testPermissionRequestUsesSharedApprovalContract() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding,
      projectRoot: "/tmp/project"
    )
    let request = DeepSeekHarnessACPPermissionRequest(
      approvalID: "deepseek-approval",
      requestID: .string("rpc-1"),
      sessionID: "session",
      toolCallID: "tool-1",
      title: "Run command",
      kind: "execute",
      rawInput: .object([
        "command": .string("swift test"),
        "path": .string("/tmp/project/Package.swift"),
      ]),
      options: [
        try AgentApprovalOption(id: "allow-once", name: "Allow", kind: "allow_once"),
        try AgentApprovalOption(id: "reject-once", name: "Reject", kind: "reject_once"),
      ]
    )

    let envelope = try await normalizer.normalize(
      .init(sequence: 0, event: .permissionRequested(request))
    )
    guard case .approvalRequested(let approval) = envelope?.event else {
      return XCTFail("Expected a standard approval request")
    }
    XCTAssertEqual(approval.approvalID, "deepseek-approval")
    XCTAssertEqual(approval.providerItemID, "tool-1")
    XCTAssertEqual(approval.kind, .command)
    XCTAssertEqual(approval.normalizedCommand, "swift test")
    XCTAssertEqual(approval.relativePaths, ["Package.swift"])
    XCTAssertEqual(approval.options.map(\.kind), ["allow_once", "reject_once"])
  }

  func testEmptyToolTitleFallsBackToKindAndThenTool() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding
    )

    let withKind = try await normalizer.normalize(
      .init(
        sequence: 0,
        event: .toolUpdated(
          .init(
            sessionID: "session",
            toolCallID: "kind-tool",
            title: "",
            kind: "execute",
            status: .inProgress,
            rawInput: nil
          )
        )
      )
    )
    let withoutKind = try await normalizer.normalize(
      .init(
        sequence: 1,
        event: .toolUpdated(
          .init(
            sessionID: "session",
            toolCallID: "plain-tool",
            title: "",
            kind: nil,
            status: .inProgress,
            rawInput: nil
          )
        )
      )
    )

    guard case .tool(let first) = withKind?.event,
      case .tool(let second) = withoutKind?.event
    else {
      return XCTFail("Expected tool updates")
    }
    XCTAssertEqual(first.name, "execute")
    XCTAssertNil(first.title)
    XCTAssertEqual(second.name, "tool")
    XCTAssertNil(second.title)
  }
}
