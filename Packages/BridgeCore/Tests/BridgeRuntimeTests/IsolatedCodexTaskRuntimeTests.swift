import BridgeCodexRPC
import BridgeCoordinator
import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeRuntime

final class IsolatedCodexTaskRuntimeTests: XCTestCase {
  func testEmitsBoundedRedactedSemanticExecutionFacts() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: semanticFactsScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let session = try await runtime.start(
      taskID: TaskID(rawValue: "task-semantic"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()

    guard case .semantic(let plan)? = await observations.next(),
      case .planChanged(let planValue) = plan.evidence
    else { return XCTFail("Expected a plan fact") }
    XCTAssertEqual(planValue.steps.first?.text, "Inspect [REDACTED]")
    XCTAssertEqual(planValue.explanation, "[REDACTED]")

    guard case .semantic(let command)? = await observations.next(),
      case .commandCompleted(let commandValue) = command.evidence
    else { return XCTFail("Expected a command fact") }
    XCTAssertEqual(commandValue.displayCommand, "[REDACTED]")
    XCTAssertEqual(commandValue.exitCode, 1)
    XCTAssertEqual(commandValue.status, .failed)

    guard case .semantic(let file)? = await observations.next(),
      case .fileChangeCompleted(let fileValue) = file.evidence
    else { return XCTFail("Expected a file-change fact") }
    XCTAssertEqual(fileValue.changeCount, 1)
    XCTAssertEqual(fileValue.status, .completed)
    XCTAssertFalse(String(describing: file).contains("secret-diff-payload"))
    let terminal = await observations.next()
    XCTAssertEqual(terminal, .turnCompleted)
  }

  func testSemanticExecutionEvidenceBudgetFailsClosed() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: semanticFactsScript(root: fixture.root.path),
      maximumSemanticEvidenceBytes: 1
    )
    addTeardownBlock { await runtime.shutdown() }
    let session = try await runtime.start(
      taskID: TaskID(rawValue: "task-semantic-budget"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()

    guard case .failed(let reason)? = await observations.next() else {
      return XCTFail("Expected the semantic evidence budget to fail closed")
    }
    XCTAssertEqual(reason, "Codex emitted invalid semantic execution evidence.")
    let streamEnd = await observations.next()
    XCTAssertNil(streamEnd)
  }

  func testNewThreadApprovalUsesAuthoritativeItemCorrelation() async throws {
    let fixture = try await makeFixture()
    let script = newThreadApprovalScript(root: fixture.root.path)
    let runtime = makeRuntime(fixture: fixture, script: script)
    addTeardownBlock { await runtime.shutdown() }
    let submission = makeSubmission(projectID: fixture.projectID, thread: .new)

    let lockKeys = try await runtime.lockKeys(for: submission, previousBinding: nil)
    XCTAssertEqual(lockKeys.count, 2)
    XCTAssertEqual(Set(lockKeys).count, 2)

    let preparation = try await runtime.prepare(
      taskID: TaskID(rawValue: "task-new"),
      submission: submission,
      previousBinding: nil
    )
    XCTAssertEqual(preparation.threadID.rawValue, "thread-new")
    XCTAssertEqual(preparation.turnGeneration, 1)
    XCTAssertEqual(preparation.lockKeys.count, 2)
    XCTAssertNotEqual(preparation.lockKeys, lockKeys)
    let session = try await runtime.startPrepared(
      taskID: TaskID(rawValue: "task-new"),
      submission: submission,
      preparation: preparation
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
    let capturedEvidence = try await runtime.approvalEvidence(
      taskID: TaskID(rawValue: "task-new"),
      approvalID: approvalID
    )
    let evidence = try XCTUnwrap(capturedEvidence)
    XCTAssertEqual(evidence.authority, .correlatedDisplayOnly)
    XCTAssertEqual(evidence.threadID.rawValue, "thread-new")
    XCTAssertEqual(evidence.turnID.rawValue, "turn-new")
    XCTAssertEqual(evidence.itemID, "item-1")
    XCTAssertEqual(evidence.displayCommand, "[REDACTED]")
    XCTAssertEqual(evidence.workingDirectory, ".")
    XCTAssertNil(evidence.fileChangeManifest)
    do {
      try await runtime.resolveApproval(
        taskID: TaskID(rawValue: "task-new"),
        approvalID: approvalID,
        approved: true
      )
      XCTFail("Expected Codex approval authorization to fail closed")
    } catch IsolatedCodexTaskRuntimeError.approvalUnavailable {}
    try await runtime.resolveApproval(
      taskID: TaskID(rawValue: "task-new"),
      approvalID: approvalID,
      approved: false
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

  func testUnsafeThreadAndTurnIdentifiersFailBeforeBinding() async throws {
    let fixture = try await makeFixture()
    let unsafeThreadRuntime = makeRuntime(
      fixture: fixture,
      script: invalidBindingIdentifierScript(root: fixture.root.path, unsafeThread: true)
    )
    addTeardownBlock { await unsafeThreadRuntime.shutdown() }
    do {
      _ = try await unsafeThreadRuntime.start(
        taskID: TaskID(rawValue: "task-unsafe-thread"),
        submission: makeSubmission(projectID: fixture.projectID, thread: .new),
        previousBinding: nil
      )
      XCTFail("Expected the unsafe Thread identifier to fail closed")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .threadMismatch)
    }

    let unsafeTurnRuntime = makeRuntime(
      fixture: fixture,
      script: invalidBindingIdentifierScript(root: fixture.root.path, unsafeThread: false)
    )
    addTeardownBlock { await unsafeTurnRuntime.shutdown() }
    do {
      _ = try await unsafeTurnRuntime.start(
        taskID: TaskID(rawValue: "task-unsafe-turn"),
        submission: makeSubmission(projectID: fixture.projectID, thread: .new),
        previousBinding: nil
      )
      XCTFail("Expected the unsafe Turn identifier to fail closed")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
  }

  func testFileApprovalPersistsCorrelatedChangedPathsWithoutRawDiff() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(fixture: fixture, script: fileApprovalScript(root: fixture.root.path))
    addTeardownBlock { await runtime.shutdown() }
    let taskID = TaskID(rawValue: "task-file-approval")
    let session = try await runtime.start(
      taskID: taskID,
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()
    guard case .codexApprovalRequested(let approvalID)? = await observations.next() else {
      return XCTFail("Expected a file approval request")
    }
    let captured = try await runtime.approvalEvidence(taskID: taskID, approvalID: approvalID)
    let evidence = try XCTUnwrap(captured)
    XCTAssertEqual(evidence.kind, .fileChange)
    XCTAssertEqual(evidence.authority, .correlatedFileChanges)
    XCTAssertEqual(evidence.changedPaths, ["Sources/App.swift", "Sources/Main.swift"])
    let manifest = try XCTUnwrap(evidence.fileChangeManifest)
    XCTAssertEqual(manifest.entries.count, 1)
    XCTAssertEqual(manifest.entries[0].path, "Sources/App.swift")
    XCTAssertEqual(manifest.entries[0].movePath, "Sources/Main.swift")
    XCTAssertEqual(manifest.entries[0].diffByteCount, "secret-diff-payload".utf8.count)
    XCTAssertEqual(manifest.totalDiffBytes, "secret-diff-payload".utf8.count)
    XCTAssertEqual(manifest.rootDevice, try RegisteredRoot(capturing: fixture.root).identity.device)
    XCTAssertEqual(manifest.rootInode, try RegisteredRoot(capturing: fixture.root).identity.inode)
    XCTAssertFalse(String(describing: evidence).contains("secret-diff-payload"))

    try await runtime.resolveApproval(taskID: taskID, approvalID: approvalID, approved: false)
    await runtime.finalizeApprovalResolution(
      taskID: taskID,
      approvalID: approvalID,
      committed: true
    )
    let completed = await observations.next()
    XCTAssertEqual(completed, .turnCompleted)
  }

  func testPermissionsApprovalPersistsClosedProfileAndRedactsExternalPaths() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: permissionsApprovalScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let taskID = TaskID(rawValue: "task-permissions-approval")
    let session = try await runtime.start(
      taskID: taskID,
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()
    guard case .codexApprovalRequested(let approvalID)? = await observations.next() else {
      return XCTFail("Expected a permissions approval request")
    }
    let captured = try await runtime.approvalEvidence(taskID: taskID, approvalID: approvalID)
    let evidence = try XCTUnwrap(captured)
    XCTAssertEqual(evidence.kind, .permissions)
    XCTAssertEqual(evidence.authority, .requestedPermissionProfile)
    XCTAssertEqual(evidence.workingDirectory, ".")
    XCTAssertTrue(evidence.displayArguments.contains("网络访问：保持关闭"))
    XCTAssertTrue(evidence.displayArguments.contains("文件系统 write：[REDACTED]"))
    XCTAssertNil(evidence.fileChangeManifest)

    try await runtime.resolveApproval(taskID: taskID, approvalID: approvalID, approved: false)
    await runtime.finalizeApprovalResolution(
      taskID: taskID,
      approvalID: approvalID,
      committed: true
    )
    let completed = await observations.next()
    XCTAssertEqual(completed, .turnCompleted)
  }

  func testDuplicateApprovalItemIdentityFailsSession() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalItemScript(root: fixture.root.path, duplicate: true)
    )
    addTeardownBlock { await runtime.shutdown() }
    let session = try await runtime.start(
      taskID: TaskID(rawValue: "task-duplicate-item"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()
    let failure = await observations.next()
    let end = await observations.next()

    XCTAssertEqual(
      failure,
      .failed(reason: "Codex emitted an invalid item event.")
    )
    XCTAssertNil(end)

    let reusedRuntime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalItemScript(
        root: fixture.root.path,
        duplicate: true,
        firstItemType: "reasoning",
        duplicateItemType: "commandExecution"
      )
    )
    addTeardownBlock { await reusedRuntime.shutdown() }
    let reusedSession = try await reusedRuntime.start(
      taskID: TaskID(rawValue: "task-reused-item"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var reusedObservations = reusedSession.observations.makeAsyncIterator()
    let reusedFailure = await reusedObservations.next()
    XCTAssertEqual(
      reusedFailure,
      .failed(reason: "Codex emitted an invalid item event.")
    )

    let reverseRuntime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalItemScript(
        root: fixture.root.path,
        duplicate: true,
        firstItemType: "commandExecution",
        duplicateItemType: "reasoning"
      )
    )
    addTeardownBlock { await reverseRuntime.shutdown() }
    let reverseSession = try await reverseRuntime.start(
      taskID: TaskID(rawValue: "task-reversed-item"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var reverseObservations = reverseSession.observations.makeAsyncIterator()
    let reverseFailure = await reverseObservations.next()
    XCTAssertEqual(
      reverseFailure,
      .failed(reason: "Codex emitted an invalid item event.")
    )
  }

  func testTerminalApprovalItemAndEvidenceBudgetFailClosed() async throws {
    let fixture = try await makeFixture()
    let terminalRuntime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalItemScript(root: fixture.root.path, status: "completed")
    )
    addTeardownBlock { await terminalRuntime.shutdown() }
    let terminalSession = try await terminalRuntime.start(
      taskID: TaskID(rawValue: "task-terminal-item"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var terminalObservations = terminalSession.observations.makeAsyncIterator()
    let terminalFailure = await terminalObservations.next()
    XCTAssertEqual(
      terminalFailure,
      .failed(reason: "Codex emitted invalid approval item evidence.")
    )

    let boundedRuntime = makeRuntime(
      fixture: fixture,
      script: invalidApprovalItemScript(root: fixture.root.path),
      maximumKnownItemEvidenceBytes: 32
    )
    addTeardownBlock { await boundedRuntime.shutdown() }
    let boundedSession = try await boundedRuntime.start(
      taskID: TaskID(rawValue: "task-bounded-evidence"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var boundedObservations = boundedSession.observations.makeAsyncIterator()
    let boundedFailure = await boundedObservations.next()
    XCTAssertEqual(
      boundedFailure,
      .failed(reason: "Codex approval evidence capacity was exceeded.")
    )
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

  func testImmediateResumeReplacesTerminatedSessionBeforeProcessCleanupFinishes() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: resumeSteerInterruptScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let taskID = TaskID(rawValue: "task-immediate-resume")
    let threadID = ThreadID(rawValue: "thread-existing")
    let submission = makeSubmission(projectID: fixture.projectID, thread: .existing(threadID))
    let first = try await runtime.start(
      taskID: taskID,
      submission: submission,
      previousBinding: nil
    )
    try await runtime.steer(
      taskID: taskID,
      binding: first.binding,
      prompt: "Finish the first generation."
    )
    try await runtime.interrupt(taskID: taskID, binding: first.binding)
    var observations = first.observations.makeAsyncIterator()
    let stopped = await observations.next()
    XCTAssertEqual(stopped, .turnStopped)

    let resumed = try await runtime.prepare(
      taskID: taskID,
      submission: submission,
      previousBinding: first.binding
    )

    XCTAssertEqual(resumed.threadID, threadID)
    XCTAssertEqual(resumed.turnGeneration, 2)
    await runtime.cancelPreparation(taskID: taskID)
  }

  func testAbortSessionRequiresExactBindingAndWaitsForShutdown() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: resumeSteerInterruptScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let taskID = TaskID(rawValue: "task-abort")
    let session = try await runtime.start(
      taskID: taskID,
      submission: makeSubmission(
        projectID: fixture.projectID,
        thread: .existing(ThreadID(rawValue: "thread-existing"))
      ),
      previousBinding: nil
    )

    do {
      try await runtime.abortSession(
        taskID: taskID,
        binding: ExecutionBinding(
          threadID: session.binding.threadID,
          turnID: TurnID(rawValue: "wrong-turn"),
          turnGeneration: session.binding.turnGeneration
        )
      )
      XCTFail("Expected the stale binding to be rejected")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .bindingMismatch)
    }

    try await runtime.abortSession(taskID: taskID, binding: session.binding)
    var observations = session.observations.makeAsyncIterator()
    let streamEnd = await observations.next()
    XCTAssertNil(streamEnd)
    do {
      try await runtime.steer(
        taskID: taskID,
        binding: session.binding,
        prompt: "This session has already stopped."
      )
      XCTFail("Expected the stopped session to be unavailable")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .sessionUnavailable)
    }
  }

  func testPreparingSuccessorRejectsStaleAbortAndDuplicatePreparation() async throws {
    let fixture = try await makeFixture()
    let location = RuntimeProjectLocation(
      workingDirectoryURL: fixture.root,
      repositoryRootURL: fixture.root
    )
    let gate = RuntimeLocationGate(location: location, blockedCall: 2)
    let runtime = makeRuntime(
      fixture: fixture,
      script: resumeSteerInterruptScript(root: fixture.root.path),
      locations: gate
    )
    addTeardownBlock { await runtime.shutdown() }
    let taskID = TaskID(rawValue: "task-preparation-reservation")
    let submission = makeSubmission(
      projectID: fixture.projectID,
      thread: .existing(ThreadID(rawValue: "thread-existing"))
    )
    let first = try await runtime.start(
      taskID: taskID,
      submission: submission,
      previousBinding: nil
    )
    try await runtime.abortSession(taskID: taskID, binding: first.binding)

    let successor = Task {
      try await runtime.prepare(
        taskID: taskID,
        submission: submission,
        previousBinding: first.binding
      )
    }
    await gate.waitUntilBlocked()

    do {
      try await runtime.abortSession(taskID: taskID, binding: first.binding)
      XCTFail("Expected a stale abort to fail while the successor is preparing")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .activeSession)
    }
    do {
      _ = try await runtime.prepare(
        taskID: taskID,
        submission: submission,
        previousBinding: first.binding
      )
      XCTFail("Expected duplicate preparation to be rejected")
    } catch {
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .activeSession)
    }

    await gate.release()
    let preparation = try await successor.value
    XCTAssertEqual(preparation.turnGeneration, 2)
    await runtime.cancelPreparation(taskID: taskID)
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

  func testTurnCompletionCannotDiscardAnUnresolvedApproval() async throws {
    let fixture = try await makeFixture()
    let runtime = makeRuntime(
      fixture: fixture,
      script: unresolvedApprovalCompletionScript(root: fixture.root.path)
    )
    addTeardownBlock { await runtime.shutdown() }
    let session = try await runtime.start(
      taskID: TaskID(rawValue: "task-unresolved-approval"),
      submission: makeSubmission(projectID: fixture.projectID, thread: .new),
      previousBinding: nil
    )
    var observations = session.observations.makeAsyncIterator()
    guard case .codexApprovalRequested? = await observations.next() else {
      return XCTFail("Expected the pending approval before the malicious completion")
    }
    guard case .failed(let reason)? = await observations.next() else {
      return XCTFail("Expected fail-closed handling for unresolved approval completion")
    }
    XCTAssertEqual(reason, "Codex completed a turn with unresolved approval requests.")
    let streamEnd = await observations.next()
    XCTAssertNil(streamEnd)
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

  private func makeRuntime(
    fixture: Fixture,
    script: String,
    maximumKnownItemEvidenceBytes: Int = 4 * 1_024 * 1_024,
    maximumSemanticEvidenceBytes: Int = 4 * 1_024 * 1_024
  ) -> IsolatedCodexTaskRuntime {
    let location = RuntimeProjectLocation(
      workingDirectoryURL: fixture.root,
      repositoryRootURL: fixture.root
    )
    return makeRuntime(
      fixture: fixture,
      script: script,
      locations: ClosureRuntimeProjectLocationResolver { _ in location },
      maximumKnownItemEvidenceBytes: maximumKnownItemEvidenceBytes,
      maximumSemanticEvidenceBytes: maximumSemanticEvidenceBytes
    )
  }

  private func makeRuntime(
    fixture: Fixture,
    script: String,
    locations: any RuntimeProjectLocationResolving,
    maximumKnownItemEvidenceBytes: Int = 4 * 1_024 * 1_024,
    maximumSemanticEvidenceBytes: Int = 4 * 1_024 * 1_024
  ) -> IsolatedCodexTaskRuntime {
    return IsolatedCodexTaskRuntime(
      registry: fixture.registry,
      locations: locations,
      configuration: IsolatedCodexTaskRuntimeConfiguration(
        appServer: AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", script]
        ),
        clientInfo: .bridge(version: "runtime-tests"),
        requestTimeoutNanoseconds: 1_000_000_000,
        startEventTimeoutNanoseconds: 1_000_000_000,
        maximumSessionNanoseconds: 5_000_000_000,
        maximumKnownItemEvidenceBytes: maximumKnownItemEvidenceBytes,
        maximumSemanticEvidenceBytes: maximumSemanticEvidenceBytes
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
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":1,"item":{"id":"item-1","type":"commandExecution","command":"/usr/bin/git status","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
        printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"item-1","approvalId":null,"startedAtMs":1,"command":"/usr/bin/git status","cwd":"__ROOT__","reason":"Inspect the working tree."}}'
        IFS= read -r approval
        case "$approval" in *'"id":"approval-1"'*) ;; *) exit 33 ;; esac
        case "$approval" in *'"decision":"decline"'*) ;; *) exit 33 ;; esac
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
  }

  private func semanticFactsScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let completed = turnJSON(id: "turn-new", status: "completed")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":1,"item":{"id":"item-message","type":"agentMessage","text":"ordinary message"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-new","turnId":"turn-new","completedAtMs":1,"item":{"id":"item-message","type":"agentMessage","text":"ordinary message"}}}'
        printf '%s\n' '{"method":"turn/plan/updated","params":{"threadId":"thread-new","turnId":"turn-new","explanation":"password=actual-secret-value","plan":[{"step":"Inspect /Users/alice/private","status":"inProgress"}]}}'
        printf '%s\n' '{"method":"turn/plan/updated","params":{"threadId":"thread-new","turnId":"turn-new","explanation":"password=actual-secret-value","plan":[{"step":"Inspect /Users/alice/private","status":"inProgress"}]}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":2,"item":{"id":"item-command","type":"commandExecution","command":"password=actual-secret-value","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-new","turnId":"turn-new","completedAtMs":3,"item":{"id":"item-command","type":"commandExecution","command":"password=actual-secret-value","commandActions":[],"cwd":"__ROOT__","status":"failed","exitCode":1,"aggregatedOutput":"must-not-persist"}}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":4,"item":{"id":"item-file","type":"fileChange","status":"inProgress","changes":[{"path":"Sources/App.swift","diff":"secret-diff-payload","kind":{"type":"update","move_path":null}}]}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-new","turnId":"turn-new","completedAtMs":5,"item":{"id":"item-file","type":"fileChange","status":"completed","changes":[{"path":"Sources/App.swift","diff":"secret-diff-payload","kind":{"type":"update","move_path":null}}]}}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
  }

  private func invalidBindingIdentifierScript(root: String, unsafeThread: Bool) -> String {
    let threadID = unsafeThread ? "/Users/alice/private-thread" : "thread-safe"
    let turnID = unsafeThread ? "turn-safe" : "password=private-turn-value"
    let thread = threadJSON(id: threadID, root: root)
    let turn = turnJSON(id: turnID, status: "inProgress")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
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

  private func fileApprovalScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let completed = turnJSON(id: "turn-new", status: "completed")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":2,"item":{"id":"item-file","type":"fileChange","status":"inProgress","changes":[{"path":"Sources/App.swift","diff":"secret-diff-payload","kind":{"type":"update","move_path":"Sources/Main.swift"}}]}}}'
        printf '%s\n' '{"id":"approval-file","method":"item/fileChange/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"item-file","startedAtMs":2,"grantRoot":"__ROOT__","reason":"Apply the requested update."}}'
        IFS= read -r approval
        case "$approval" in *'"id":"approval-file"'*) ;; *) exit 61 ;; esac
        case "$approval" in *'"decision":"decline"'*) ;; *) exit 61 ;; esac
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
  }

  private func permissionsApprovalScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let completed = turnJSON(id: "turn-new", status: "completed")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":3,"item":{"id":"item-command","type":"commandExecution","command":"tool run","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
        printf '%s\n' '{"id":"approval-permissions","method":"item/permissions/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"item-command","startedAtMs":3,"cwd":"__ROOT__","permissions":{"fileSystem":{"entries":[{"access":"write","path":{"type":"path","path":"/private/outside"}}]},"network":{"enabled":false}},"reason":"Request a bounded permission profile."}}'
        IFS= read -r approval
        case "$approval" in *'"id":"approval-permissions"'*) ;; *) exit 62 ;; esac
        case "$approval" in *'"permissions":{}'*) ;; *) exit 62 ;; esac
        case "$approval" in *'"scope":"turn"'*) ;; *) exit 62 ;; esac
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
  }

  private func invalidApprovalItemScript(
    root: String,
    status: String = "inProgress",
    duplicate: Bool = false,
    firstItemType: String = "commandExecution",
    duplicateItemType: String? = nil
  ) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let item =
      #"{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":1,"item":{"id":"item-1","type":"__TYPE__","command":"tool run","commandActions":[],"cwd":"__ROOT__","status":"__STATUS__"}}}"#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__STATUS__", with: status)
      .replacingOccurrences(of: "__TYPE__", with: firstItemType)
    let repeated =
      duplicateItemType.map {
        item.replacingOccurrences(of: #""type":"\#(firstItemType)""#, with: #""type":"\#($0)""#)
      } ?? item
    let duplicateItem = duplicate ? "printf '%s\\n' '\(repeated)'" : ""
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '__ITEM__'
        __DUPLICATE__
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__ITEM__", with: item)
      .replacingOccurrences(of: "__DUPLICATE__", with: duplicateItem)
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

  private func unresolvedApprovalCompletionScript(root: String) -> String {
    let thread = threadJSON(id: "thread-new", root: root)
    let turn = turnJSON(id: "turn-new", status: "inProgress")
    let completed = turnJSON(id: "turn-new", status: "completed")
    return commonHandshake
      + "\n"
        + #"""
        IFS= read -r thread_start
        printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
        IFS= read -r turn_start
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-new","turn":__TURN__}}'
        printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
        printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-new","turnId":"turn-new","startedAtMs":1,"item":{"id":"item-1","type":"commandExecution","command":"/usr/bin/git status","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
        printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-new","turnId":"turn-new","itemId":"item-1","approvalId":null,"startedAtMs":1,"command":"/usr/bin/git status","cwd":"__ROOT__"}}'
        sleep 0.1
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-new","turn":__COMPLETED__}}'
        sleep 2
        """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__TURN__", with: turn)
      .replacingOccurrences(of: "__COMPLETED__", with: completed)
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

private actor RuntimeLocationGate: RuntimeProjectLocationResolving {
  private let location: RuntimeProjectLocation
  private let blockedCall: Int
  private var calls = 0
  private var isBlocked = false
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  init(location: RuntimeProjectLocation, blockedCall: Int) {
    self.location = location
    self.blockedCall = blockedCall
  }

  func location(for _: TaskSubmission) async -> RuntimeProjectLocation {
    calls += 1
    guard calls == blockedCall else { return location }
    isBlocked = true
    for waiter in blockedWaiters {
      waiter.resume()
    }
    blockedWaiters.removeAll(keepingCapacity: false)
    await withCheckedContinuation { releaseWaiter = $0 }
    return location
  }

  func waitUntilBlocked() async {
    if isBlocked { return }
    await withCheckedContinuation { blockedWaiters.append($0) }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
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
