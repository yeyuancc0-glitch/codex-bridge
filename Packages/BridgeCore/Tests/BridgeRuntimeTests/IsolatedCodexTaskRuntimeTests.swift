import BridgeCodexRPC
import BridgeCoordinator
import BridgeDomain
import BridgeProjects
import Foundation
import XCTest

@testable import BridgeRuntime

final class IsolatedCodexTaskRuntimeTests: XCTestCase {
  func testNewThreadApprovalUsesAuthoritativeItemCorrelation() async throws {
    let fixture = try await makeFixture()
    let script = newThreadApprovalScript(root: fixture.root.path)
    let runtime = makeRuntime(fixture: fixture, script: script)
    addTeardownBlock { await runtime.shutdown() }
    let submission = makeSubmission(projectID: fixture.projectID, thread: .new)

    let lockKeys = try await runtime.lockKeys(for: submission, previousBinding: nil)
    XCTAssertEqual(lockKeys.count, 2)
    XCTAssertEqual(Set(lockKeys).count, 2)

    let session = try await runtime.start(
      taskID: TaskID(rawValue: "task-new"),
      submission: submission,
      previousBinding: nil
    )
    XCTAssertEqual(session.binding.threadID.rawValue, "thread-new")
    XCTAssertEqual(session.binding.turnID.rawValue, "turn-new")
    XCTAssertEqual(session.binding.turnGeneration, 1)
    let recorder = ObservationRecorder()
    let collector = Task {
      for await observation in session.observations {
        await recorder.append(observation)
      }
      await recorder.finish()
    }
    defer { collector.cancel() }
    guard
      case .codexApprovalRequested(let approvalID) = try await recorder.waitForEvent(at: 0)
    else {
      return XCTFail("Expected a correlated approval request")
    }
    try await runtime.resolveApproval(
      taskID: TaskID(rawValue: "task-new"),
      approvalID: approvalID,
      approved: true
    )
    try await Task.sleep(nanoseconds: 100_000_000)
    let eventsBeforeCommit = await recorder.snapshot()
    XCTAssertEqual(eventsBeforeCommit, [.codexApprovalRequested(approvalID)])

    await runtime.finalizeApprovalResolution(
      taskID: TaskID(rawValue: "task-new"),
      approvalID: approvalID,
      committed: true
    )
    let completed = try await recorder.waitForEvent(at: 1)
    XCTAssertEqual(completed, .turnCompleted)
    try await recorder.waitForEnd()
  }

  func testExistingThreadResumeAdvancesGenerationAndBindsSteerAndInterrupt() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: resumeSteerInterruptScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let threadID = ThreadID(rawValue: "thread-existing")
    let submission = makeSubmission(
      projectID: fixture.projectID,
      thread: .existing(threadID)
    )
    let previous = ExecutionBinding(
      threadID: threadID,
      turnID: TurnID(rawValue: "turn-previous"),
      turnGeneration: 1
    )
    let initialKeys = try await runtime.lockKeys(for: submission, previousBinding: nil)
    let resumedKeys = try await runtime.lockKeys(for: submission, previousBinding: previous)
    XCTAssertEqual(initialKeys, resumedKeys)

    let taskID = TaskID(rawValue: "task-resume")
    let session = try await runtime.start(
      taskID: taskID,
      submission: submission,
      previousBinding: previous
    )
    XCTAssertEqual(session.binding.threadID, threadID)
    XCTAssertEqual(session.binding.turnID.rawValue, "turn-resumed")
    XCTAssertEqual(session.binding.turnGeneration, 2)

    do {
      try await runtime.steer(
        taskID: taskID,
        binding: ExecutionBinding(
          threadID: threadID,
          turnID: TurnID(rawValue: "wrong-turn"),
          turnGeneration: 2
        ),
        prompt: "This must not reach Codex."
      )
      XCTFail("Expected exact active-binding enforcement")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .bindingMismatch)
    }
    try await runtime.steer(
      taskID: taskID,
      binding: session.binding,
      prompt: "Keep the same approved scope."
    )
    try await runtime.interrupt(taskID: taskID, binding: session.binding)
    var observations = session.observations.makeAsyncIterator()
    let stopped = await observations.next()
    let streamEnd = await observations.next()
    XCTAssertEqual(stopped, .turnStopped)
    XCTAssertNil(streamEnd)
  }

  func testApprovalWithoutStartedItemFailsClosed() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    do {
      let session = try await runtime.start(
        taskID: TaskID(rawValue: "task-invalid-approval"),
        submission: makeSubmission(projectID: fixture.projectID, thread: .new),
        previousBinding: nil
      )
      var observations = session.observations.makeAsyncIterator()
      guard case .failed(let reason)? = await observations.next() else {
        return XCTFail("Expected fail-closed approval handling")
      }
      XCTAssertEqual(reason, "Codex approval correlation was invalid.")
      let streamEnd = await observations.next()
      XCTAssertNil(streamEnd)
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .sessionEnded)
    }
  }

  private struct Fixture {
    let root: URL
    let projectID: ProjectID
    let registry: ProjectRegistry
  }

  private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-runtime-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(
        name: "Runtime Fixture",
        rootURL: canonicalRoot,
        accessPolicy: .init(read: .allowed, write: .allowed, network: .allowed)
      )
    )
    return Fixture(root: canonicalRoot, projectID: project.id, registry: registry)
  }

  private func makeRuntime(fixture: Fixture, script: String) -> IsolatedCodexTaskRuntime {
    let location = RuntimeProjectLocation(
      workingDirectoryURL: fixture.root,
      repositoryRootURL: fixture.root
    )
    return IsolatedCodexTaskRuntime(
      registry: fixture.registry,
      locations: ClosureRuntimeProjectLocationResolver { _ in location },
      configuration: IsolatedCodexTaskRuntimeConfiguration(
        appServer: AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", script]
        ),
        clientInfo: .bridge(version: "runtime-tests"),
        requestTimeoutNanoseconds: 1_000_000_000,
        startEventTimeoutNanoseconds: 1_000_000_000,
        maximumSessionNanoseconds: 5_000_000_000
      )
    )
  }

  private func makeSubmission(projectID: ProjectID, thread: ThreadTarget) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "runtime-fixture"),
      projectID: projectID,
      thread: thread,
      execution: ExecutionOptions(
        model: "fixture-model",
        effort: "medium",
        permissionMode: "workspace-write",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: false, model: "", effort: ""),
      contract: TaskContract(
        goal: "Exercise the isolated runtime.",
        acceptanceCriteria: ["The fake turn reaches its terminal event."]
      )
    )
  }

  private func newThreadApprovalScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let completed = turnJSON(id: "turn-new", status: "completed")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 31 ;; esac
        case "$thread_start" in *'"ephemeral":false'*) ;; *) exit 31 ;; esac
        case "$thread_start" in *'"cwd":"__ROOT__"'*) ;; *) exit 31 ;; esac
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 32 ;; esac
        case "$turn_start" in *'"threadId":"thread-new"'*) ;; *) exit 32 ;; esac
        case "$turn_start" in *'"effort":"medium"'*) ;; *) exit 32 ;; esac
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":1,"item":{"id":"item-1","type":"commandExecution"}}}'
        printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"item-1","approvalId":null,"startedAtMs":1}}'
        IFS= read -r approval
        case "$approval" in *'"id":"approval-1"'*) ;; *) exit 33 ;; esac
        case "$approval" in *'"decision":"accept"'*) ;; *) exit 33 ;; esac
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
  }

  private func resumeSteerInterruptScript(root: String) -> String {
    let thread = threadJSON(id: "thread-existing", root: root)
    let turn = turnJSON(id: "turn-resumed", status: "inProgress")
    let interrupted = turnJSON(id: "turn-resumed", status: "interrupted")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_read
        case "$thread_read" in *'"method":"thread/read"'*) ;; *) exit 41 ;; esac
        case "$thread_read" in *'"threadId":"thread-existing"'*) ;; *) exit 41 ;; esac
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__}}'
        IFS= read -r thread_resume
        case "$thread_resume" in *'"method":"thread/resume"'*) ;; *) exit 42 ;; esac
        case "$thread_resume" in *'"threadId":"thread-existing"'*) ;; *) exit 42 ;; esac
        case "$thread_resume" in *'"cwd":"__ROOT__"'*) ;; *) exit 42 ;; esac
        printf '%s\n' '{"id":4,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-existing","turn":__TURN__}}'
        printf '%s\n' '{"id":5,"result":{"turn":__TURN__}}'
        IFS= read -r steer
        case "$steer" in *'"method":"turn/steer"'*) ;; *) exit 43 ;; esac
        case "$steer" in *'"expectedTurnId":"turn-resumed"'*) ;; *) exit 43 ;; esac
        printf '%s\n' '{"id":6,"result":{"turnId":"turn-resumed"}}'
        IFS= read -r interrupt
        case "$interrupt" in *'"method":"turn/interrupt"'*) ;; *) exit 44 ;; esac
        case "$interrupt" in *'"turnId":"turn-resumed"'*) ;; *) exit 44 ;; esac
        printf '%s\n' '{"id":7,"result":{}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-existing","turn":__INTERRUPTED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__INTERRUPTED__", with: interrupted)
  }

  private func invalidApprovalScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"id":"approval-invalid","method":"item/fileChange/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"never-started","startedAtMs":1}}'
        IFS= read -r rejection
        case "$rejection" in *'"id":"approval-invalid"'*) ;; *) exit 51 ;; esac
        case "$rejection" in *'"error"'*) ;; *) exit 51 ;; esac
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
  }

  private var commonHandshake: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r models
    printf '%s\n' '{"id":2,"result":{"data":[{"id":"fixture-model","model":"fixture-model","displayName":"Fixture","description":"fixture","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":true}],"nextCursor":null}}'
    """#
  }

  private func threadJSON(id: String, root: String) -> String {
    """
    {"id":"\(id)","cwd":"\(root)","ephemeral":false,"modelProvider":"fixture","preview":"","turns":[],"name":null,"cliVersion":"fixture/1","createdAt":1,"updatedAt":1,"sessionId":"session-1","status":{"type":"idle"},"source":"appServer"}
    """
  }

  private func turnJSON(id: String, status: String) -> String {
    """
    {"id":"\(id)","status":"\(status)","error":null,"items":[],"itemsView":"full","startedAt":1,"completedAt":null,"durationMs":null}
    """
  }
}

private actor ObservationRecorder {
  private var events: [TaskExecutionObservation] = []
  private var ended = false

  func append(_ observation: TaskExecutionObservation) {
    events.append(observation)
  }

  func snapshot() -> [TaskExecutionObservation] {
    events
  }

  func waitForEvent(at index: Int) async throws -> TaskExecutionObservation {
    for _ in 0..<200 {
      if events.indices.contains(index) { return events[index] }
      if ended { throw ObservationRecorderError.streamEnded }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw ObservationRecorderError.timeout
  }

  func waitForEnd() async throws {
    for _ in 0..<200 {
      if ended { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw ObservationRecorderError.timeout
  }

  func finish() {
    ended = true
  }
}

private enum ObservationRecorderError: Error {
  case streamEnded
  case timeout
}
