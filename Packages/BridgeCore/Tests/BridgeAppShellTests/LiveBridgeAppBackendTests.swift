import BridgeAppModel
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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-app-shell-backend-\(UUID().uuidString)",
      isDirectory: true
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
