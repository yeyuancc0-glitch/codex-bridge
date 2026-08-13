import BridgeApplication
import BridgeCoordinator
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgePersistence
import BridgeProjects
import BridgeReporting
import BridgeRepositories
import BridgeSecurity
import Foundation
import XCTest

final class BridgeApplicationServiceTests: XCTestCase {
  func testProjectAndThreadQueriesNeverExposeCanonicalPathsOrSecrets() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let root = try RegisteredRoot(capturing: fixture.projectDirectory)
    let project = fixture.project(root: root)
    try await fixture.repository.insert(project)
    let catalog = CatalogFixture(
      threads: [
        CatalogThread(
          threadID: "thr-safe",
          cwd: root.canonicalPath,
          title: "Bridge task",
          status: "idle",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
          preview:
            "Opened file:///Users/example/private.txt and ](/Volumes/private/file) with Bearer abcdefghijklmnop",
          entries: [
            CatalogThreadEntry(
              turnID: "turn-safe",
              role: "assistant",
              text:
                "Read file:///Volumes/private/secret.txt, ](/Users/example/secret), and api_key=abcdefghijklmnop"
            )
          ]
        )
      ]
    )
    let service = fixture.service(catalog: catalog)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let projects = try await service.listMCPVisibleProjects(
      cursor: nil,
      limit: 25,
      deadline: deadline
    )
    XCTAssertEqual(projects.projects.map(\.projectID), [project.id.rawValue])
    XCTAssertFalse(try encoded(projects).contains(root.canonicalPath))

    let threads = try await service.listThreads(
      projectID: project.id.rawValue,
      cursor: nil,
      limit: 25,
      search: nil,
      deadline: deadline
    )
    XCTAssertEqual(threads.threads.map(\.threadID), ["thr-safe"])
    XCTAssertFalse(try encoded(threads).contains("/Users/"))
    XCTAssertFalse(try encoded(threads).contains("/Volumes/"))
    XCTAssertFalse(try encoded(threads).contains("abcdefghijklmnop"))

    let read = try await service.readThread(
      projectID: project.id.rawValue,
      threadID: "thr-safe",
      detail: .full,
      cursor: nil,
      limit: 25,
      deadline: deadline
    )
    XCTAssertEqual(read.entries.count, 1)
    XCTAssertFalse(read.entries[0].text.contains("/Volumes/"))
    XCTAssertFalse(read.entries[0].text.contains("abcdefghijklmnop"))
  }

  func testOpenInCodexRequiresThreadBoundToRequestedProject() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let root = try RegisteredRoot(capturing: fixture.projectDirectory)
    let project = fixture.project(root: root)
    try await fixture.repository.insert(project)
    let foreignDirectory = fixture.directory.appendingPathComponent("foreign", isDirectory: true)
    try FileManager.default.createDirectory(
      at: foreignDirectory,
      withIntermediateDirectories: false
    )
    let catalog = CatalogFixture(
      threads: [
        CatalogThread(
          threadID: "thr-bound",
          cwd: root.canonicalPath,
          status: "idle"
        ),
        CatalogThread(
          threadID: "thr-foreign",
          cwd: foreignDirectory.path,
          status: "idle"
        ),
      ]
    )
    let recorder = OpenURLRecorder()
    let service = fixture.service(catalog: catalog) { url in
      await recorder.open(url)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    do {
      _ = try await service.openInCodex(
        projectID: project.id.rawValue,
        threadID: "thr-foreign",
        deadline: deadline
      )
      XCTFail("Expected a foreign thread to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .threadNotFound)
    }
    let beforeOpen = await recorder.openedURLs()
    XCTAssertTrue(beforeOpen.isEmpty)

    let receipt = try await service.openInCodex(
      projectID: project.id.rawValue,
      threadID: "thr-bound",
      deadline: deadline
    )
    XCTAssertTrue(receipt.opened)
    let opened = await recorder.openedURLs()
    XCTAssertEqual(opened.map(\.absoluteString), ["codex://threads/thr-bound"])
  }

  func testSubmissionReceiptReportsStableReplayAndEventsArePayloadFree() async throws {
    let fixture = try Fixture(admission: .requireLocalApproval)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let project = fixture.project(
      root: try RegisteredRoot(capturing: fixture.projectDirectory)
    )
    try await fixture.repository.insert(project)
    let service = fixture.service()
    let submission = fixture.submission(projectID: project.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let first = try await service.submitTask(submission, deadline: deadline)
    let replay = try await service.submitTask(submission, deadline: deadline)

    XCTAssertEqual(first.taskID, replay.taskID)
    XCTAssertFalse(first.reusedExistingTask)
    XCTAssertTrue(replay.reusedExistingTask)
    XCTAssertTrue(first.localApprovalRequired)

    let events = try await service.getTaskEvents(
      taskID: first.taskID,
      afterSequence: nil,
      limit: 1,
      deadline: deadline
    )
    XCTAssertEqual(events.events.count, 1)
    XCTAssertEqual(events.events[0].kind, "task.submission")
    XCTAssertEqual(events.nextAfterSequence, 1)
    XCTAssertNil(events.events[0].summary)
  }

  func testProjectFileToolsUseRelativePathsAndRedactSecrets() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let project = fixture.project(
      root: try RegisteredRoot(capturing: fixture.projectDirectory)
    )
    try await fixture.repository.insert(project)
    let sourceDirectory = fixture.projectDirectory.appendingPathComponent(
      "Sources",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: false
    )
    try Data(
      "needle file:///Users/example/private.txt ](/Volumes/private/file)\nAPI_KEY=1234567890123456\n"
        .utf8
    ).write(
      to: sourceDirectory.appendingPathComponent("App.swift")
    )
    let service = fixture.service()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let detail = try await service.getProject(
      projectID: project.id.rawValue,
      deadline: deadline
    )
    XCTAssertEqual(detail.projectID, project.id.rawValue)
    XCTAssertFalse(try encoded(detail).contains(project.primaryRoot.canonicalPath))

    let search = try await service.searchProjectFiles(
      projectID: project.id.rawValue,
      query: "needle",
      relativeDirectory: nil,
      caseSensitive: false,
      cursor: nil,
      limit: 25,
      deadline: deadline
    )
    XCTAssertEqual(search.matches.map(\.relativePath), ["Sources/App.swift"])
    XCTAssertFalse(search.matches[0].preview.contains("/Users/"))
    XCTAssertFalse(search.matches[0].preview.contains("/Volumes/"))

    let read = try await service.readProjectFile(
      projectID: project.id.rawValue,
      relativePath: "Sources/App.swift",
      startLine: 1,
      lineCount: 3,
      deadline: deadline
    )
    XCTAssertTrue(read.content.contains("[REDACTED: suspected secret]"))
    XCTAssertFalse(read.content.contains("1234567890123456"))
    XCTAssertFalse(read.content.contains("/Users/"))
    XCTAssertFalse(read.content.contains("/Volumes/"))
  }

  func testProjectFileSanitizationPreservesSourceAndReportsAdditionalRedaction() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let project = fixture.project(
      root: try RegisteredRoot(capturing: fixture.projectDirectory)
    )
    try await fixture.repository.insert(project)
    let source =
      "/// doc comment\n//TODO: preserve\n/* block comment */\nreturn /foo/.test(value)\nlet path = \"/Users/example/private.txt\"\nlet network = \"//Users/example/network\"\nlet doc = \"///Volumes/example/doc\"\nlet block = \"/*Users/example/block\""
    try Data(source.utf8).write(to: fixture.projectDirectory.appendingPathComponent("Syntax.swift"))
    let service = fixture.service()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let search = try await service.searchProjectFiles(
      projectID: project.id.rawValue,
      query: "private.txt",
      relativeDirectory: nil,
      caseSensitive: true,
      cursor: nil,
      limit: 25,
      deadline: deadline
    )
    XCTAssertEqual(search.matches.count, 1)
    XCTAssertTrue(search.matches[0].redacted)
    XCTAssertFalse(search.matches[0].preview.contains("/Users/"))

    let read = try await service.readProjectFile(
      projectID: project.id.rawValue,
      relativePath: "Syntax.swift",
      startLine: 1,
      lineCount: 8,
      deadline: deadline
    )
    XCTAssertTrue(read.content.contains("/// doc comment"))
    XCTAssertTrue(read.content.contains("//TODO: preserve"))
    XCTAssertTrue(read.content.contains("/* block comment */"))
    XCTAssertTrue(read.content.contains("return /foo/.test(value)"))
    XCTAssertFalse(read.content.contains("/Users/"))
    XCTAssertFalse(read.content.contains("/Volumes/"))
    XCTAssertFalse(read.content.contains("example/block"))
    XCTAssertEqual(read.redactedLineCount, 4)
  }

  func testSteerRequiresExpectedTurnAndMutationReceiptsUsePersistedOperationIDs() async throws {
    let runtime = RuntimeFixture()
    let fixture = try Fixture(admission: .start, runtime: runtime)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let project = fixture.project(
      root: try RegisteredRoot(capturing: fixture.projectDirectory)
    )
    try await fixture.repository.insert(project)
    let service = fixture.service()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let receipt = try await service.submitTask(
      fixture.submission(projectID: project.id),
      deadline: deadline
    )
    try await waitForPhase(.running, taskID: receipt.taskID, service: service)

    do {
      _ = try await service.steerTask(
        taskID: receipt.taskID,
        expectedTurnID: "wrong-turn",
        input: "Continue with the accepted contract.",
        deadline: deadline
      )
      XCTFail("Expected the stale turn to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .turnMismatch)
    }

    let steer = try await service.steerTask(
      taskID: receipt.taskID,
      expectedTurnID: "turn-live",
      input: "Continue with the accepted contract.",
      deadline: deadline
    )
    XCTAssertTrue(steer.accepted)
    XCTAssertTrue(steer.operationID.hasPrefix("op_"))

    let interrupted = try await service.interruptTask(
      taskID: receipt.taskID,
      deadline: deadline
    )
    XCTAssertTrue(interrupted.operationID.hasPrefix("op_"))
    XCTAssertNotEqual(interrupted.operationID, steer.operationID)
  }

  func testFinalReportMappingRemovesAbsoluteCommandPaths() async throws {
    let fixture = try Fixture(admission: .requireLocalApproval)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let project = fixture.project(
      root: try RegisteredRoot(capturing: fixture.projectDirectory)
    )
    try await fixture.repository.insert(project)
    let service = fixture.service()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let receipt = try await service.submitTask(
      fixture.submission(projectID: project.id),
      deadline: deadline
    )
    let document = try report(taskID: receipt.taskID, project: project.name)
    _ = try await fixture.repository.storeFinalReport(document, storedAt: Date())

    let mapped = try await service.getFinalReport(taskID: receipt.taskID, deadline: deadline)

    XCTAssertEqual(mapped.taskID, receipt.taskID)
    XCTAssertEqual(mapped.commands, ["xcrun swift test [REDACTED_PATH] exit=0"])
    XCTAssertFalse(try encoded(mapped).contains("/usr/"))
    XCTAssertFalse(try encoded(mapped).contains("/Users/"))
  }

  private func waitForPhase(
    _ phase: TaskPhase,
    taskID: String,
    service: BridgeApplicationService
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      let task = try await service.getTask(
        taskID: taskID,
        deadline: deadline
      )
      if task.phase == phase.rawValue { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Task did not reach \(phase.rawValue)")
  }

  private func encoded<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private func report(taskID: String, project: String) throws -> FinalReportDocument {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    return try ReportBuilder().build(
      from: FinalReportInput(
        taskID: taskID,
        status: .completed,
        project: project,
        appServer: AppServerEvidence(
          threadID: "thr-report",
          model: "gpt-test",
          effort: "high",
          terminalState: .completed,
          commands: [
            AppServerCommandEvidence(
              sequence: 1,
              executable: "/usr/bin/xcrun",
              arguments: ["swift", "test", "/Users/example/project"],
              exitCode: 0
            )
          ],
          startedAt: started,
          completedAt: started.addingTimeInterval(10)
        ),
        git: GitEvidence(
          baselineCaptured: true,
          finalStateCaptured: true,
          dirtyAtStart: false,
          changedFiles: [
            GitChangedFileEvidence(relativePath: "Sources/App.swift", change: .modified)
          ],
          diffStat: "1 file changed"
        ),
        verification: [
          VerificationEvidence(
            id: "test",
            name: "swift test",
            required: true,
            status: .passed,
            exitCode: 0
          )
        ],
        supervisor: SupervisorEvidence(
          model: "gpt-5.6-luna",
          effort: "medium",
          checks: 1,
          steers: 0,
          finalDecision: .finalAccept
        ),
        policy: PolicyEvidence(evaluationCompleted: true)
      )
    )
  }
}

private final class Fixture: @unchecked Sendable {
  let directory: URL
  let projectDirectory: URL
  let eventStore: EventStore
  let repository: ApplicationRepository
  let coordinator: TaskCoordinator

  init(
    admission: AdmissionFixture.Decision = .requireLocalApproval,
    runtime: RuntimeFixture = RuntimeFixture()
  ) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-application-\(UUID().uuidString)", isDirectory: true)
    projectDirectory = directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let databasePath = directory.appendingPathComponent("bridge.sqlite").path
    eventStore = try EventStore(path: databasePath)
    repository = try ApplicationRepository(path: databasePath)
    coordinator = TaskCoordinator(
      store: eventStore,
      admission: AdmissionFixture(decision: admission),
      runtime: runtime
    )
  }

  func service(
    catalog: CatalogFixture = CatalogFixture(),
    openCodexURL: @escaping @Sendable (URL) async -> Bool = { _ in false }
  ) -> BridgeApplicationService {
    BridgeApplicationService(
      coordinator: coordinator,
      eventStore: eventStore,
      projectRepository: repository,
      reportStore: repository,
      catalog: catalog,
      status: BridgeStatusStore(
        initial: BridgeStatusSnapshot(
          appVersion: "test",
          mcpState: "ready",
          tunnelState: "stopped",
          executionState: "idle",
          supervisorState: "idle",
          pendingApprovalCount: 0
        )
      ),
      openCodexURL: openCodexURL
    )
  }

  func project(root: RegisteredRoot) -> RegisteredProject {
    RegisteredProject(
      id: ProjectID(rawValue: "prj_application"),
      name: "Codex Bridge",
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: ProjectAccessPolicy(),
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  func submission(projectID: ProjectID) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "idem-application"),
      projectID: projectID,
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-test",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "gpt-5.6-luna", effort: "medium"),
      contract: TaskContract(
        goal: "Build the accepted feature.",
        requirements: ["Preserve compatibility."],
        acceptanceCriteria: ["Tests pass."]
      )
    )
  }
}

private actor OpenURLRecorder {
  private var urls: [URL] = []

  func open(_ url: URL) -> Bool {
    urls.append(url)
    return true
  }

  func openedURLs() -> [URL] {
    urls
  }
}

private struct AdmissionFixture: TaskAdmissionPolicy {
  enum Decision: Sendable {
    case start
    case requireLocalApproval
  }

  let decision: Decision

  func decision(for submission: TaskSubmission) -> TaskAdmissionDecision {
    switch decision {
    case .start: .start
    case .requireLocalApproval: .requireLocalApproval
    }
  }
}

private actor RuntimeFixture: TaskExecutionRuntime {
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]

  func lockKeys(for submission: TaskSubmission) -> [String] {
    ["thread:\(submission.idempotencyKey.rawValue)", "worktree:\(submission.projectID.rawValue)"]
      .sorted()
  }

  func start(taskID: TaskID, submission _: TaskSubmission) -> TaskExecutionSession {
    let pair = AsyncStream<TaskExecutionObservation>.makeStream()
    continuations[taskID] = pair.continuation
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: ThreadID(rawValue: "thr-live"),
        turnID: TurnID(rawValue: "turn-live"),
        turnGeneration: 1
      ),
      observations: pair.stream
    )
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) {}

  func steer(taskID _: TaskID, binding _: ExecutionBinding, prompt _: String) {}

  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) {}
}

private actor CatalogFixture: CodexCatalogQuerying {
  let threads: [CatalogThread]

  init(threads: [CatalogThread] = []) {
    self.threads = threads
  }

  func listThreads(
    canonicalWorkingDirectories _: [String],
    cursor _: String?,
    limit: Int,
    search _: String?,
    deadline _: ContinuousClock.Instant
  ) -> CatalogThreadPage {
    CatalogThreadPage(threads: Array(threads.prefix(limit)))
  }

  func readThread(
    threadID: String,
    includeTurns _: Bool,
    deadline _: ContinuousClock.Instant
  ) throws -> CatalogThread {
    guard let thread = threads.first(where: { $0.threadID == threadID }) else {
      throw BridgeMCPQueryError.threadNotFound
    }
    return thread
  }

  func listModels(deadline _: ContinuousClock.Instant) -> [CatalogModel] {
    [
      CatalogModel(
        id: "gpt-test", displayName: "GPT Test", isDefault: true, reasoningEfforts: ["high"])
    ]
  }
}
