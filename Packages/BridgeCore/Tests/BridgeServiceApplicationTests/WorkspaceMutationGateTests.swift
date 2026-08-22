import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeServiceApplication
import BridgeServiceCore
import Crypto
import Foundation
import XCTest

final class WorkspaceMutationGateTests: XCTestCase {
  private func projectID(_ raw: String) -> ProjectID {
    ProjectID(rawValue: raw)
  }

  private func activeWriteTaskClosure(_ tasks: ServiceTaskManager)
    -> @Sendable () async throws -> ServiceTaskRecord?
  {
    { try await tasks.activeWriteTask(projectID: ProjectID(rawValue: "prj-gate")) }
  }

  func testDirectLeaseBlocksASecondDirectOperationOnSameProject() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let tasks = ServiceTaskManager(store: try SimpleServiceStore.inMemory())

    let first = try await gate.acquireDirectLease(
      projectID: projectID("prj-gate"),
      owner: .directFileOperation(operationID: "op-1"),
      activeCodexWriteTask: activeWriteTaskClosure(tasks)
    )
    let activeOwner = await gate.activeDirectOwner(projectID: projectID("prj-gate"))
    XCTAssertEqual(activeOwner, first.owner)

    do {
      _ = try await gate.acquireDirectLease(
        projectID: projectID("prj-gate"),
        owner: .directFileOperation(operationID: "op-2"),
        activeCodexWriteTask: activeWriteTaskClosure(tasks)
      )
      XCTFail("Expected the second direct lease to be rejected")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "direct_file")
      XCTAssertEqual(detail.operationID, "op-1")
    }

    await first.release()
    let third = try await gate.acquireDirectLease(
      projectID: projectID("prj-gate"),
      owner: .directFileOperation(operationID: "op-3"),
      activeCodexWriteTask: activeWriteTaskClosure(tasks)
    )
    XCTAssertEqual(third.owner, .directFileOperation(operationID: "op-3"))
  }

  func testDirectLeaseBlocksCodexAdmissionAndViceVersa() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let tasks = ServiceTaskManager(store: try SimpleServiceStore.inMemory())

    let lease = try await gate.acquireDirectLease(
      projectID: projectID("prj-gate"),
      owner: .directCommand(sessionID: "cmd-1"),
      activeCodexWriteTask: activeWriteTaskClosure(tasks)
    )
    do {
      try await gate.beginCodexAdmission(projectID: projectID("prj-gate"))
      XCTFail("Expected Codex admission to be rejected while a Direct lease is held")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "direct_command")
      XCTAssertEqual(detail.sessionID, "cmd-1")
    }
    await lease.release()

    try await gate.beginCodexAdmission(projectID: projectID("prj-gate"))
    do {
      _ = try await gate.acquireDirectLease(
        projectID: projectID("prj-gate"),
        owner: .directFileOperation(operationID: "op-1"),
        activeCodexWriteTask: activeWriteTaskClosure(tasks)
      )
      XCTFail("Expected a Direct lease to be rejected while Codex admission is pending")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "codex_task")
    }
    await gate.endCodexAdmission(projectID: projectID("prj-gate"))

    let leaseAfter = try await gate.acquireDirectLease(
      projectID: projectID("prj-gate"),
      owner: .directFileOperation(operationID: "op-1"),
      activeCodexWriteTask: activeWriteTaskClosure(tasks)
    )
    XCTAssertEqual(leaseAfter.owner, .directFileOperation(operationID: "op-1"))
  }

  func testActiveCodexWriteTaskBlocksDirectLeaseWithTaskID() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let store = try SimpleServiceStore.inMemory()
    let tasks = ServiceTaskManager(
      store: store,
      makeTaskID: { TaskID(rawValue: "tsk-active-write") }
    )
    let projects = ServiceProjectService(store: store)
    _ = try await projects.register(
      name: "Gate Project",
      rootURL: FileManager.default.temporaryDirectory,
      id: projectID("prj-gate")
    )
    _ = try await tasks.submit(
      ServiceTaskRequest(
        projectID: projectID("prj-gate"),
        source: .chatGPT,
        prompt: "Fix the bug",
        executionModel: "model-a",
        executionEffort: "high",
        permissionMode: .workspaceWrite
      )
    )

    do {
      _ = try await gate.acquireDirectLease(
        projectID: projectID("prj-gate"),
        owner: .directFileOperation(operationID: "op-1"),
        activeCodexWriteTask: activeWriteTaskClosure(tasks)
      )
      XCTFail("Expected an active Codex write task to block the Direct lease")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "codex_task")
      XCTAssertEqual(detail.taskID, "tsk-active-write")
    }
  }

  func testUnknownCodexWriteTaskStillOccupiesTheWorkspace() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let store = try SimpleServiceStore.inMemory()
    let tasks = ServiceTaskManager(
      store: store,
      makeTaskID: { TaskID(rawValue: "tsk-unknown-write") }
    )
    let projects = ServiceProjectService(store: store)
    _ = try await projects.register(
      name: "Gate Project",
      rootURL: FileManager.default.temporaryDirectory,
      id: projectID("prj-gate")
    )
    let submitted = try await tasks.submit(
      ServiceTaskRequest(
        projectID: projectID("prj-gate"),
        source: .chatGPT,
        prompt: "Fix the bug",
        executionModel: "model-a",
        executionEffort: "high",
        permissionMode: .workspaceWrite
      )
    )
    _ = try await tasks.begin(taskID: submitted.task.id)
    try await tasks.recoverIncompleteTasks()

    do {
      _ = try await gate.acquireDirectLease(
        projectID: projectID("prj-gate"),
        owner: .directFileOperation(operationID: "op-1"),
        activeCodexWriteTask: activeWriteTaskClosure(tasks)
      )
      XCTFail("Expected an unknown Codex write task to still occupy the workspace")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "codex_task")
      XCTAssertEqual(detail.taskID, "tsk-unknown-write")
    }
  }

  func testDifferentProjectsRunInParallel() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let tasks = ServiceTaskManager(store: try SimpleServiceStore.inMemory())

    let first = try await gate.acquireDirectLease(
      projectID: projectID("prj-alpha"),
      owner: .directFileOperation(operationID: "op-a"),
      activeCodexWriteTask: {
        try await tasks.activeWriteTask(projectID: ProjectID(rawValue: "prj-alpha"))
      }
    )
    let second = try await gate.acquireDirectLease(
      projectID: projectID("prj-beta"),
      owner: .directFileOperation(operationID: "op-b"),
      activeCodexWriteTask: {
        try await tasks.activeWriteTask(projectID: ProjectID(rawValue: "prj-beta"))
      }
    )
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    _ = await first.release()
    _ = await second.release()
  }

  func testConcurrentDirectAdmissionsAllowOnlyOneOwnerPerProject() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let store = try SimpleServiceStore.inMemory()
    let projects = ServiceProjectService(store: store)
    _ = try await projects.register(
      name: "Concurrent Project",
      rootURL: FileManager.default.temporaryDirectory,
      id: projectID("prj-concurrent")
    )
    let tasks = ServiceTaskManager(store: store)

    await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          do {
            let lease = try await gate.acquireDirectLease(
              projectID: ProjectID(rawValue: "prj-concurrent"),
              owner: .directFileOperation(operationID: "op-\(index)"),
              activeCodexWriteTask: {
                try await tasks.activeWriteTask(projectID: ProjectID(rawValue: "prj-concurrent"))
              }
            )
            try await Task.sleep(for: .milliseconds(20))
            await lease.release()
          } catch {
            guard case ProjectWorkspaceBusyError.busy = error else {
              throw error
            }
          }
        }
      }
    }
    let activeOwner = await gate.activeDirectOwner(projectID: projectID("prj-concurrent"))
    XCTAssertNil(activeOwner)
  }

  func testConcurrentCodexAdmissionsUseReferenceCountedTokens() async throws {
    let gate = ServiceWorkspaceMutationGate()
    let project = projectID("prj-admission-tokens")

    try await gate.beginCodexAdmission(projectID: project)
    try await gate.beginCodexAdmission(projectID: project)
    await gate.endCodexAdmission(projectID: project)

    do {
      _ = try await gate.acquireDirectLease(
        projectID: project,
        owner: .directFileOperation(operationID: "op-still-pending"),
        activeCodexWriteTask: { nil }
      )
      XCTFail("One remaining Codex admission must keep the workspace busy")
    } catch let error as ProjectWorkspaceBusyError {
      guard case .busy(let detail) = error else {
        return XCTFail("Unexpected busy error")
      }
      XCTAssertEqual(detail.owner, "codex_task")
    }

    await gate.endCodexAdmission(projectID: project)
    let lease = try await gate.acquireDirectLease(
      projectID: project,
      owner: .directFileOperation(operationID: "op-after-admissions"),
      activeCodexWriteTask: { nil }
    )
    await lease.release()
  }

  func testReadProjectFileReturnsFullFileDigestAndRevision() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let source = fixture.root.appending(path: "Feature.swift")
    let bytes = Data("line one\nline two\nline three\n".utf8)
    try bytes.write(to: source)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let page = try await application.serviceReadProjectFile(
      projectID: fixture.project.id.rawValue,
      relativePath: "Feature.swift",
      startLine: 1,
      lineCount: 2,
      deadline: deadline
    )
    XCTAssertEqual(page.content, "line one\nline two")
    XCTAssertEqual(page.sha256, digest)
    XCTAssertEqual(page.byteCount, bytes.count)
    XCTAssertEqual(page.fileRevision, "sha256:\(digest)")
  }
}
