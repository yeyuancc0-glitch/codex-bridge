import BridgeAppModel
import BridgeApplication
import BridgeDomain
import BridgeMCP
import BridgePresentation
import Foundation
import XCTest

@testable import BridgeAppShell

final class LiveBridgeAppBackendTests: XCTestCase {
  func testBootstrapPublishesHonestDisabledCapabilities() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let system = await TestDesktopSystemService(selectedDirectory: nil)
    let backend = LiveBridgeAppBackend(dataDirectoryURL: directory, system: system)
    let stream = await backend.stateUpdates()
    var iterator = stream.makeAsyncIterator()

    let snapshot = try await nextReadySnapshot(&iterator)

    guard case .ready(let connection) = snapshot.presentation.connections,
      case .ready(let logs) = snapshot.presentation.logs,
      case .ready(let threads) = snapshot.presentation.threads
    else {
      return XCTFail("Expected ready presentation states")
    }
    XCTAssertEqual(snapshot.connectionState, .stopped)
    XCTAssertFalse(connection.canTest)
    XCTAssertFalse(connection.canChangeReceiving)
    XCTAssertTrue(logs.canExport)
    XCTAssertTrue(threads.threads.isEmpty)
    await backend.shutdown()
  }

  func testProjectRegistrationPersistsAcrossBackendRestart() async throws {
    let root = temporaryDirectory()
    let directory = root.appendingPathComponent("Data", isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let firstSystem = await TestDesktopSystemService(selectedDirectory: project)
    let first = LiveBridgeAppBackend(dataDirectoryURL: directory, system: firstSystem)
    let firstStream = await first.stateUpdates()
    var firstIterator = firstStream.makeAsyncIterator()
    _ = try await nextReadySnapshot(&firstIterator)

    try await first.addProject()
    let registered = try await nextProjectSnapshot(&firstIterator, count: 1)
    guard case .ready(let page) = registered.presentation.projects,
      let projectPresentation = page.projects.first
    else {
      return XCTFail("Expected registered project")
    }
    XCTAssertEqual(projectPresentation.name, "Project")
    XCTAssertFalse(projectPresentation.threadCountIsKnown)
    XCTAssertFalse(projectPresentation.gitFactsKnown)
    XCTAssertEqual(projectPresentation.readPermission, .allowed)
    XCTAssertEqual(projectPresentation.writePermission, .requiresLocalApproval)
    XCTAssertEqual(projectPresentation.networkPermission, .denied)
    XCTAssertTrue(projectPresentation.canWrite)
    XCTAssertFalse(projectPresentation.networkAllowed)
    await first.shutdown()

    let secondSystem = await TestDesktopSystemService(selectedDirectory: nil)
    let second = LiveBridgeAppBackend(dataDirectoryURL: directory, system: secondSystem)
    let secondStream = await second.stateUpdates()
    var secondIterator = secondStream.makeAsyncIterator()
    let restored = try await nextProjectSnapshot(&secondIterator, count: 1)

    guard case .ready(let restoredPage) = restored.presentation.projects else {
      return XCTFail("Expected persisted project")
    }
    XCTAssertEqual(restoredPage.projects.map(\.name), ["Project"])
    await second.shutdown()
  }

  func testIncompleteTaskActionsFailClosed() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let system = await TestDesktopSystemService(selectedDirectory: nil)
    let backend = LiveBridgeAppBackend(dataDirectoryURL: directory, system: system)

    do {
      _ = try await backend.submit(
        BridgeAppTaskSubmission(
          requestID: "request-1",
          projectID: "project-1",
          goal: "Do work",
          acceptanceCriteria: ["Done"],
          model: "model",
          effort: "medium",
          permissionMode: "read-only",
          networkAllowed: false
        )
      )
      XCTFail("Expected task pipeline to remain disabled")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .taskPipelineUnavailable)
    }
    await backend.shutdown()
  }

  func testThreadCatalogHistoryPaginationAndScopedOpenUseRegisteredProject() async throws {
    let root = temporaryDirectory()
    let directory = root.appendingPathComponent("Data", isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let system = await TestDesktopSystemService(selectedDirectory: project)
    let catalog = TestCodexCatalog(projectURL: project)
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: directory,
      system: system,
      catalog: catalog
    )
    let stream = await backend.stateUpdates()
    var iterator = stream.makeAsyncIterator()
    _ = try await nextReadySnapshot(&iterator)
    try await backend.addProject()
    let registered = try await nextProjectSnapshot(&iterator, count: 1)
    guard case .ready(let projects) = registered.presentation.projects,
      let projectID = projects.projects.first?.id
    else { return XCTFail("Expected a registered project") }

    try await backend.refresh(.threads)
    let catalogSnapshot = try await nextThreadSnapshot(&iterator, count: 1)
    guard case .ready(let threadPage) = catalogSnapshot.presentation.threads,
      let thread = threadPage.threads.first
    else { return XCTFail("Expected a Codex thread") }
    XCTAssertEqual(thread.projectID, projectID)
    XCTAssertEqual(thread.id, "thread-1")
    XCTAssertTrue(thread.canReadHistory)
    XCTAssertTrue(thread.canContinue)
    XCTAssertFalse(thread.modelIsKnown)

    try await backend.readThreadHistory(projectID: projectID, threadID: thread.id)
    let firstHistory = try await nextHistorySnapshot(&iterator, count: 100)
    guard case .ready(let firstPage) = firstHistory.presentation.threads,
      case .ready(let history)? = firstPage.history
    else { return XCTFail("Expected thread history") }
    XCTAssertEqual(history.entries.first?.text, "message-0")
    XCTAssertTrue(history.canLoadMore)

    try await backend.loadMoreThreadHistory()
    let completeHistory = try await nextHistorySnapshot(&iterator, count: 101)
    guard case .ready(let completePage) = completeHistory.presentation.threads,
      case .ready(let complete)? = completePage.history
    else { return XCTFail("Expected complete thread history") }
    XCTAssertEqual(complete.entries.last?.text, "message-100")
    XCTAssertFalse(complete.canLoadMore)

    try await backend.openThreadInCodex(projectID: projectID, threadID: thread.id)
    let openedURLs = await system.openedURLs
    XCTAssertEqual(openedURLs.last?.absoluteString, "codex://threads/thread-1")
    let requestedRoots = await catalog.requestedRoots
    XCTAssertEqual(requestedRoots, [[project.path]])

    try await backend.prepareReadOnlyTask(projectID: projectID, threadID: thread.id)
    let composerSnapshot = try await nextComposerSnapshot(&iterator)
    guard case .ready(let taskPage) = composerSnapshot.presentation.tasks,
      case .ready(let composer)? = taskPage.readOnlyComposer
    else { return XCTFail("Expected a read-only task composer") }
    XCTAssertEqual(composer.executionModels.map(\.id), ["execution-model"])
    XCTAssertEqual(composer.supervisorModels.map(\.id), ["gpt-5.6-luna"])
    XCTAssertEqual(composer.blocker, DesktopSupervisorAvailability.degradation)
    let submission = try LiveBridgeAppBackend.readOnlySubmission(
      ReadOnlyTaskDraftPresentation(
        requestID: composer.requestID,
        projectID: projectID,
        threadID: thread.id,
        goal: "Inspect the project without modifications.",
        acceptanceCriteria: ["Return a bounded report."],
        executionModel: "execution-model",
        executionEffort: "high",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium"
      ),
      requestID: composer.requestID,
      composer: DesktopLocalTaskComposer(
        requestID: composer.requestID,
        projectID: projectID,
        threadID: thread.id,
        models: [
          MCPModelSummary(
            modelID: "execution-model",
            displayName: "Execution",
            isDefault: true,
            reasoningEfforts: ["low", "high"]
          ),
          MCPModelSummary(
            modelID: "gpt-5.6-luna",
            displayName: "Luna",
            isDefault: false,
            reasoningEfforts: ["medium"]
          ),
        ],
        isSubmitting: false,
        submittedDraft: nil
      )
    )
    XCTAssertEqual(submission.execution.permissionMode, "read-only")
    XCTAssertFalse(submission.execution.networkAccess)
    XCTAssertTrue(submission.supervisor.enabled)
    XCTAssertEqual(submission.thread, .existing(ThreadID(rawValue: thread.id)))
    await backend.shutdown()
  }

  func testThreadAndHistoryCatalogQueriesAreSingleFlight() async throws {
    let root = temporaryDirectory()
    let directory = root.appendingPathComponent("Data", isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let system = await TestDesktopSystemService(selectedDirectory: project)
    let catalog = GatedCodexCatalog(projectURL: project)
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: directory,
      system: system,
      catalog: catalog
    )
    let stream = await backend.stateUpdates()
    var iterator = stream.makeAsyncIterator()
    _ = try await nextReadySnapshot(&iterator)
    try await backend.addProject()
    let registered = try await nextProjectSnapshot(&iterator, count: 1)
    guard case .ready(let projects) = registered.presentation.projects,
      let projectID = projects.projects.first?.id
    else { return XCTFail("Expected a registered project") }

    let firstRefresh = Task { try await backend.refresh(.threads) }
    await catalog.waitUntilStarted(.threads)
    do {
      try await backend.refresh(.threads)
      XCTFail("Expected a concurrent Thread refresh to be rejected")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .operationFailed)
    }
    await catalog.release(.threads)
    try await firstRefresh.value
    _ = try await nextThreadSnapshot(&iterator, count: 1)

    let firstHistory = Task {
      try await backend.readThreadHistory(projectID: projectID, threadID: "thread-gated")
    }
    await catalog.waitUntilStarted(.history)
    do {
      try await backend.readThreadHistory(projectID: projectID, threadID: "thread-gated")
      XCTFail("Expected a concurrent Thread history read to be rejected")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .operationFailed)
    }
    await catalog.release(.history)
    try await firstHistory.value

    let firstOpen = Task {
      try await backend.openThreadInCodex(projectID: projectID, threadID: "thread-gated")
    }
    await catalog.waitUntilStarted(.open)
    do {
      try await backend.openThreadInCodex(projectID: projectID, threadID: "thread-gated")
      XCTFail("Expected a concurrent scoped open to be rejected")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .operationFailed)
    }
    await catalog.release(.open)
    try await firstOpen.value
    let calls = await catalog.callCounts
    XCTAssertEqual(calls.threads, 1)
    XCTAssertEqual(calls.history, 1)
    XCTAssertEqual(calls.open, 1)
    await backend.shutdown()
  }

  func testSupportBundleExportsOnlyTypedRedactedFacts() async throws {
    let root = temporaryDirectory()
    let directory = root.appendingPathComponent("Data", isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let system = await TestDesktopSystemService(selectedDirectory: project)
    let backend = LiveBridgeAppBackend(dataDirectoryURL: directory, system: system)
    let stream = await backend.stateUpdates()
    var iterator = stream.makeAsyncIterator()
    _ = try await nextReadySnapshot(&iterator)
    try await backend.addProject()

    try await backend.exportSupportBundle()

    let bundles = await system.savedSupportBundles
    let data = try XCTUnwrap(bundles.first)
    XCTAssertEqual(bundles.count, 1)
    XCTAssertLessThan(data.count, 1_024 * 1_024)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains(root.path))
    XCTAssertFalse(text.lowercased().contains("token"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    let records = try XCTUnwrap(object["records"] as? [[String: Any]])
    let connection = try XCTUnwrap(
      records.first { $0["source"] as? String == "connection_status" }
    )
    let fields = try XCTUnwrap(connection["fields"] as? [[String: Any]])
    XCTAssertTrue(
      fields.contains {
        $0["key"] as? String == "registered_project_count" && $0["value"] as? String == "1"
      }
    )
    await backend.shutdown()
  }

  func testSupportBundleExportIsSingleFlight() async throws {
    let root = temporaryDirectory()
    let directory = root.appendingPathComponent("Data", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let system = BlockingDesktopSystemService()
    let backend = LiveBridgeAppBackend(dataDirectoryURL: directory, system: system)
    let stream = await backend.stateUpdates()
    var iterator = stream.makeAsyncIterator()
    _ = try await nextReadySnapshot(&iterator)

    let first = Task { try await backend.exportSupportBundle() }
    await system.waitUntilSaveBegins()
    do {
      try await backend.exportSupportBundle()
      XCTFail("Expected a concurrent export to be rejected")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .operationFailed)
    }
    await system.finishSave()
    try await first.value
    let saveCount = await system.saveCount
    XCTAssertEqual(saveCount, 1)
    await backend.shutdown()
  }

  private func nextReadySnapshot(
    _ iterator: inout AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Iterator
  ) async throws -> BridgeAppStateSnapshot {
    for _ in 0..<10 {
      guard let snapshot = try await iterator.next() else {
        throw TestFailure.streamEnded
      }
      if case .ready = snapshot.presentation.overview { return snapshot }
    }
    throw TestFailure.snapshotMissing
  }

  private func nextProjectSnapshot(
    _ iterator: inout AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Iterator,
    count: Int
  ) async throws -> BridgeAppStateSnapshot {
    for _ in 0..<10 {
      guard let snapshot = try await iterator.next() else {
        throw TestFailure.streamEnded
      }
      if case .ready(let page) = snapshot.presentation.projects,
        page.projects.count == count
      {
        return snapshot
      }
    }
    throw TestFailure.snapshotMissing
  }

  private func nextThreadSnapshot(
    _ iterator: inout AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Iterator,
    count: Int
  ) async throws -> BridgeAppStateSnapshot {
    for _ in 0..<12 {
      guard let snapshot = try await iterator.next() else { throw TestFailure.streamEnded }
      if case .ready(let page) = snapshot.presentation.threads,
        page.threads.count == count,
        page.isCatalogLoaded
      {
        return snapshot
      }
    }
    throw TestFailure.snapshotMissing
  }

  private func nextHistorySnapshot(
    _ iterator: inout AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Iterator,
    count: Int
  ) async throws -> BridgeAppStateSnapshot {
    for _ in 0..<12 {
      guard let snapshot = try await iterator.next() else { throw TestFailure.streamEnded }
      if case .ready(let page) = snapshot.presentation.threads,
        case .ready(let history)? = page.history,
        history.entries.count == count,
        !history.isLoadingMore
      {
        return snapshot
      }
    }
    throw TestFailure.snapshotMissing
  }

  private func nextComposerSnapshot(
    _ iterator: inout AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Iterator
  ) async throws -> BridgeAppStateSnapshot {
    for _ in 0..<12 {
      guard let snapshot = try await iterator.next() else { throw TestFailure.streamEnded }
      if case .ready(let page) = snapshot.presentation.tasks,
        case .ready? = page.readOnlyComposer
      {
        return snapshot
      }
    }
    throw TestFailure.snapshotMissing
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-app-shell-backend-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

private actor TestCodexCatalog: CodexCatalogQuerying {
  private let projectURL: URL
  private(set) var requestedRoots: [[String]] = []

  init(projectURL: URL) {
    self.projectURL = projectURL
  }

  func listThreads(
    canonicalWorkingDirectories: [String],
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) throws -> CatalogThreadPage {
    guard cursor == nil, limit == 100, search == nil, ContinuousClock.now < deadline else {
      throw BridgeApplicationError.invalidArgument
    }
    requestedRoots.append(canonicalWorkingDirectories)
    return CatalogThreadPage(threads: [thread(includeTurns: false)])
  }

  func readThread(
    threadID: String,
    includeTurns: Bool,
    deadline: ContinuousClock.Instant
  ) throws -> CatalogThread {
    guard threadID == "thread-1", ContinuousClock.now < deadline else {
      throw BridgeApplicationError.invalidArgument
    }
    return thread(includeTurns: includeTurns)
  }

  func listModels(deadline: ContinuousClock.Instant) throws -> [CatalogModel] {
    guard ContinuousClock.now < deadline else { throw BridgeApplicationError.deadlineExceeded }
    return [
      CatalogModel(
        id: "execution-model",
        displayName: "Execution",
        isDefault: true,
        reasoningEfforts: ["low", "high"]
      ),
      CatalogModel(
        id: "gpt-5.6-luna",
        displayName: "Luna",
        isDefault: false,
        reasoningEfforts: ["medium"]
      ),
    ]
  }

  private func thread(includeTurns: Bool) -> CatalogThread {
    CatalogThread(
      threadID: "thread-1",
      cwd: projectURL.path,
      title: "Fixture thread",
      status: "idle",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      preview: "A bounded fixture thread",
      entries: includeTurns
        ? (0...100).map {
          CatalogThreadEntry(
            turnID: "turn-\($0 / 2)",
            role: $0.isMultiple(of: 2) ? "user" : "assistant",
            text: "message-\($0)",
            status: "completed"
          )
        }
        : []
    )
  }
}

private actor GatedCodexCatalog: CodexCatalogQuerying {
  enum Operation: Hashable, Sendable {
    case threads
    case history
    case open
  }

  private let projectURL: URL
  private var started: Set<Operation> = []
  private var startWaiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]
  private var releaseWaiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]
  private var threadCalls = 0
  private var historyCalls = 0
  private var openCalls = 0

  init(projectURL: URL) {
    self.projectURL = projectURL
  }

  var callCounts: (threads: Int, history: Int, open: Int) {
    (threadCalls, historyCalls, openCalls)
  }

  func listThreads(
    canonicalWorkingDirectories: [String],
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThreadPage {
    guard canonicalWorkingDirectories == [projectURL.path], cursor == nil, limit == 100,
      search == nil, ContinuousClock.now < deadline
    else { throw BridgeApplicationError.invalidArgument }
    threadCalls += 1
    await pause(.threads)
    return CatalogThreadPage(threads: [thread()])
  }

  func readThread(
    threadID: String,
    includeTurns: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThread {
    guard threadID == "thread-gated", ContinuousClock.now < deadline else {
      throw BridgeApplicationError.invalidArgument
    }
    let operation: Operation
    if historyCalls == 0 {
      historyCalls += 1
      operation = .history
    } else {
      openCalls += 1
      operation = .open
    }
    await pause(operation)
    return thread(includeTurns: includeTurns)
  }

  func listModels(deadline: ContinuousClock.Instant) throws -> [CatalogModel] {
    guard ContinuousClock.now < deadline else { throw BridgeApplicationError.deadlineExceeded }
    return []
  }

  func waitUntilStarted(_ operation: Operation) async {
    if started.contains(operation) { return }
    await withCheckedContinuation { startWaiters[operation, default: []].append($0) }
  }

  func release(_ operation: Operation) {
    let waiters = releaseWaiters.removeValue(forKey: operation) ?? []
    for waiter in waiters { waiter.resume() }
  }

  private func pause(_ operation: Operation) async {
    started.insert(operation)
    let observers = startWaiters.removeValue(forKey: operation) ?? []
    for observer in observers { observer.resume() }
    await withCheckedContinuation { releaseWaiters[operation, default: []].append($0) }
  }

  private func thread(includeTurns: Bool = false) -> CatalogThread {
    CatalogThread(
      threadID: "thread-gated",
      cwd: projectURL.path,
      title: "Gated Thread",
      status: "idle",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      preview: "Gated catalog response",
      entries: includeTurns
        ? [CatalogThreadEntry(turnID: "turn-gated", role: "assistant", text: "bounded")]
        : []
    )
  }
}

private enum TestFailure: Error {
  case streamEnded
  case snapshotMissing
}

@MainActor
private final class TestDesktopSystemService: DesktopSystemServing {
  private let selectedDirectory: URL?
  private(set) var openedURLs: [URL] = []
  private(set) var copiedValues: [String] = []
  private(set) var savedSupportBundles: [Data] = []

  init(selectedDirectory: URL?) {
    self.selectedDirectory = selectedDirectory
  }

  var supportsSupportBundleExport: Bool { true }

  func selectProjectDirectory() async -> URL? { selectedDirectory }

  func open(_ url: URL) -> Bool {
    openedURLs.append(url)
    return true
  }

  func copyToPasteboard(_ value: String) -> Bool {
    copiedValues.append(value)
    return true
  }

  func saveSupportBundle(
    _ data: Data,
    suggestedFileName _: String
  ) async -> DesktopSupportBundleSaveResult {
    savedSupportBundles.append(data)
    return .saved
  }

  func showMainWindow() {}
  func terminateApplication() {}
}

@MainActor
private final class BlockingDesktopSystemService: DesktopSystemServing {
  private var saveStarted = false
  private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveWaiter: CheckedContinuation<DesktopSupportBundleSaveResult, Never>?
  private(set) var saveCount = 0

  var supportsSupportBundleExport: Bool { true }

  func selectProjectDirectory() async -> URL? { nil }
  func open(_: URL) -> Bool { false }
  func copyToPasteboard(_: String) -> Bool { false }

  func saveSupportBundle(
    _: Data,
    suggestedFileName _: String
  ) async -> DesktopSupportBundleSaveResult {
    saveCount += 1
    saveStarted = true
    let waiters = saveStartWaiters
    saveStartWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return await withCheckedContinuation { saveWaiter = $0 }
  }

  func waitUntilSaveBegins() async {
    if saveStarted { return }
    await withCheckedContinuation { saveStartWaiters.append($0) }
  }

  func finishSave() {
    saveWaiter?.resume(returning: .saved)
    saveWaiter = nil
  }

  func showMainWindow() {}
  func terminateApplication() {}
}
