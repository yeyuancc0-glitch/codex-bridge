import BridgeDomain
import BridgeProjects
import Foundation
import XCTest

@testable import BridgeCodexRPC
@testable import BridgeExecution

final class ProjectBoundCodexClientTests: XCTestCase {
  func testStartBindsOnlyExactRegisteredCWD() async throws {
    let root = try makeScratchDirectory()
    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(
        name: "Project",
        rootURL: root,
        accessPolicy: .init(read: .allowed, write: .denied, network: .denied)
      )
    )
    let rpc = FakeCodexTaskClient(startResponse: makeStartResponse(cwd: root.path))
    let bindings = InMemoryThreadBindingRepository()
    let client = ProjectBoundCodexClient(registry: registry, client: rpc, bindings: bindings)

    let response = try await client.startReadOnlyThread(
      projectID: project.id,
      workingDirectoryURL: root,
      model: "fixture-model"
    )

    XCTAssertEqual(response.thread.id, "thread-1")
    let sent = await rpc.lastThreadStart
    XCTAssertEqual(sent?.cwd, root.path)
    XCTAssertEqual(sent?.sandbox, .readOnly)
    XCTAssertEqual(sent?.approvalPolicy, .never)
    let binding = await bindings.binding(for: "thread-1")
    XCTAssertEqual(binding?.projectID, project.id)
    XCTAssertEqual(binding?.root.canonicalPath, root.path)
  }

  func testMismatchedResponseCWDIsNeverBound() async throws {
    let root = try makeScratchDirectory()
    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: root)
    )
    let rpc = FakeCodexTaskClient(startResponse: makeStartResponse(cwd: "/tmp/wrong"))
    let bindings = InMemoryThreadBindingRepository()
    let client = ProjectBoundCodexClient(registry: registry, client: rpc, bindings: bindings)

    do {
      _ = try await client.startReadOnlyThread(
        projectID: project.id,
        workingDirectoryURL: root
      )
      XCTFail("Expected cwd mismatch")
    } catch {
      XCTAssertEqual(error as? ProjectExecutionError, .workingDirectoryMismatch)
    }
    let binding = await bindings.binding(for: "thread-1")
    XCTAssertNil(binding)
  }

  func testReadDeniedProjectNeverStartsRPCThread() async throws {
    let root = try makeScratchDirectory()
    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(
        name: "Project",
        rootURL: root,
        accessPolicy: .init(read: .denied, write: .denied, network: .denied)
      )
    )
    let rpc = FakeCodexTaskClient(startResponse: makeStartResponse(cwd: root.path))
    let client = ProjectBoundCodexClient(
      registry: registry,
      client: rpc,
      bindings: InMemoryThreadBindingRepository()
    )

    do {
      _ = try await client.startReadOnlyThread(
        projectID: project.id,
        workingDirectoryURL: root
      )
      XCTFail("Expected project read denial")
    } catch {
      XCTAssertEqual(error as? ProjectExecutionError, .projectReadDenied)
    }
    let sent = await rpc.lastThreadStart
    XCTAssertNil(sent)
  }

  private func makeStartResponse(cwd: String) -> ThreadStartResponse {
    ThreadStartResponse(
      thread: makeThread(cwd: cwd),
      model: "fixture-model",
      modelProvider: "fixture",
      reasoningEffort: "low",
      cwd: cwd,
      sandbox: .readOnly(),
      approvalPolicy: .never,
      approvalsReviewer: "user",
      serviceTier: nil
    )
  }

  private func makeThread(cwd: String) -> CodexThread {
    CodexThread(
      id: "thread-1",
      cwd: cwd,
      ephemeral: true,
      modelProvider: "fixture",
      preview: "",
      turns: [],
      name: nil,
      cliVersion: "fixture",
      createdAt: 1,
      updatedAt: 1,
      sessionId: "session-1",
      status: .object([:]),
      source: .string("appServer")
    )
  }

  private func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "bridge-execution-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }
}

private actor FakeCodexTaskClient: CodexTaskClient {
  private let startResponse: ThreadStartResponse
  private(set) var lastThreadStart: ThreadStartParams?

  init(startResponse: ThreadStartResponse) {
    self.startResponse = startResponse
  }

  func startThread(_ params: ThreadStartParams) -> ThreadStartResponse {
    lastThreadStart = params
    return startResponse
  }

  func readThread(_ params: ThreadReadParams) -> ThreadReadResponse {
    ThreadReadResponse(thread: startResponse.thread)
  }
}
