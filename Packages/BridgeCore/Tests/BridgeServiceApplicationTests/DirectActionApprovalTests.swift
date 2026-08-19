import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class DirectActionApprovalCenterTests: XCTestCase {
  func testRequestReturnsApprovalIDAndApproveConsumesGrantOnce() async {
    let center = DirectActionApprovalCenter()
    let id = await center.request(
      projectID: "prj-1",
      kind: .fileWrite,
      summary: "Write README.md",
      payloadDigest: "digest-a",
      clientRequestID: "req-1"
    )
    XCTAssertTrue(id.hasPrefix("appr-"))

    let pending = await center.pendingApprovals()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].approvalID, id)

    let consumedBeforeApprove = await center.consume(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(consumedBeforeApprove)
    let approved = await center.approve(approvalID: id)
    XCTAssertTrue(approved)
    let consumedOnce = await center.consume(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertTrue(consumedOnce)
    let consumedTwice = await center.consume(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(consumedTwice)
  }

  func testPayloadDigestBindsApprovalToExactRequest() async {
    let center = DirectActionApprovalCenter()
    let id = await center.request(
      projectID: "prj-1",
      kind: .command,
      summary: "Run test",
      payloadDigest: "digest-a",
      clientRequestID: nil
    )
    let approved = await center.approve(approvalID: id)
    XCTAssertTrue(approved)
    let consumed = await center.consume(payloadDigest: "digest-a", clientRequestID: nil)
    XCTAssertTrue(consumed)
    let wrongDigest = await center.consume(payloadDigest: "digest-b", clientRequestID: nil)
    XCTAssertFalse(wrongDigest)
  }

  func testDenySurfacesDenialOnRetry() async {
    let center = DirectActionApprovalCenter(denyLifetime: 30)
    let id = await center.request(
      projectID: "prj-1",
      kind: .fileWrite,
      summary: "Write",
      payloadDigest: "digest-a",
      clientRequestID: "req-1"
    )
    let denied = await center.deny(approvalID: id)
    XCTAssertTrue(denied)
    let consumed = await center.consume(payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(consumed)
    let retryID = await center.request(
      projectID: "prj-1",
      kind: .fileWrite,
      summary: "Write",
      payloadDigest: "digest-a",
      clientRequestID: "req-1"
    )
    XCTAssertNotEqual(retryID, id)
    let approved = await center.approve(approvalID: retryID)
    XCTAssertTrue(approved)
    let consumedAfterApprove = await center.consume(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertTrue(consumedAfterApprove)
  }

  func testExpiryInvalidatesPendingApprovals() async {
    let center = DirectActionApprovalCenter(approvalLifetime: 0.1)
    _ = await center.request(
      projectID: "prj-1",
      kind: .command,
      summary: "Run",
      payloadDigest: "digest-a",
      clientRequestID: nil
    )
    try? await Task.sleep(for: .milliseconds(150))
    let pending = await center.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
  }

  func testRestartInvalidatesAllPendingApprovals() async {
    let first = DirectActionApprovalCenter()
    let id = await first.request(
      projectID: "prj-1",
      kind: .command,
      summary: "Run",
      payloadDigest: "digest-a",
      clientRequestID: "req-1"
    )
    let restarted = DirectActionApprovalCenter()
    let restartedPending = await restarted.pendingApprovals()
    XCTAssertTrue(restartedPending.isEmpty)
    let consumed = await restarted.consume(payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(consumed)
    let approved = await restarted.approve(approvalID: id)
    XCTAssertFalse(approved)
  }

  func testPayloadDigestStableForEncodableRequests() throws {
    let request = MCPDirectWriteRequest(
      projectID: "prj-1",
      relativePath: "README.md",
      mode: "create",
      content: "hello",
      expectedSHA256: nil,
      createParents: false,
      clientRequestID: "req-1"
    )
    let a = DirectActionApprovalCenter.payloadDigest(request)
    let b = DirectActionApprovalCenter.payloadDigest(request)
    XCTAssertEqual(a, b)
    XCTAssertEqual(a.count, 64)
  }
}

final class DirectApprovalFlowTests: XCTestCase {
  func testDirectWriteRequiresLocalApprovalThenSucceedsOnReplay() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let target = fixture.root.appending(path: "ApprovedFile.txt")

    let first = MCPDirectWriteRequest(
      projectID: fixture.project.id.rawValue,
      relativePath: "ApprovedFile.txt",
      mode: "create",
      content: "first",
      expectedSHA256: nil,
      createParents: false,
      clientRequestID: "req-approve-1"
    )
    do {
      _ = try await application.serviceDirectWriteFile(first, deadline: deadline)
      XCTFail("Expected approval_required")
    } catch let error as BridgeMCPQueryError {
      guard case .approvalRequired(let approvalID) = error else {
        return XCTFail("Expected approvalRequired, got \(error)")
      }
      let pending = await application.approvals.pendingApprovals()
      XCTAssertEqual(pending.map(\.approvalID), [approvalID])
      let approved = await application.approvals.approve(approvalID: approvalID)
      XCTAssertTrue(approved)
    }

    // Replay with identical payload + clientRequestID consumes the one-time grant.
    let second = MCPDirectWriteRequest(
      projectID: fixture.project.id.rawValue,
      relativePath: "ApprovedFile.txt",
      mode: "create",
      content: "first",
      expectedSHA256: nil,
      createParents: false,
      clientRequestID: "req-approve-1"
    )
    let receipt = try await application.serviceDirectWriteFile(second, deadline: deadline)
    XCTAssertEqual(receipt.relativePath, "ApprovedFile.txt")
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "first")
  }

  func testDirectWriteDeniedDoesNotCreateFile() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let request = MCPDirectWriteRequest(
      projectID: fixture.project.id.rawValue,
      relativePath: "DeniedFile.txt",
      mode: "create",
      content: "should-not-exist",
      expectedSHA256: nil,
      createParents: false,
      clientRequestID: "req-deny-1"
    )
    do {
      _ = try await application.serviceDirectWriteFile(request, deadline: deadline)
      XCTFail("Expected approval_required")
    } catch let error as BridgeMCPQueryError {
      guard case .approvalRequired(let approvalID) = error else {
        return XCTFail("Expected approvalRequired, got \(error)")
      }
      let denied = await application.approvals.deny(approvalID: approvalID)
      XCTAssertTrue(denied)
    }
    do {
      _ = try await application.serviceDirectWriteFile(request, deadline: deadline)
      XCTFail("Expected approval_required after denial")
    } catch let error as BridgeMCPQueryError {
      guard case .approvalRequired = error else {
        return XCTFail("Expected approvalRequired, got \(error)")
      }
    }
    let target = fixture.root.appending(path: "DeniedFile.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testDirectExecCommandRequiresApprovalForElevatedCommand() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .registered,
      workspaceCommands: [
        try ServiceWorkspaceCommand(
          id: "wcmd-deploy",
          name: "Deploy",
          executable: "/bin/echo",
          arguments: ["deploying"],
          requiresNetwork: false,
          risk: .elevated
        )
      ],
      projectID: fixture.project.id
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let request = MCPDirectExecRequest(
      projectID: fixture.project.id.rawValue,
      commandID: "wcmd-deploy",
      argv: [],
      workingDirectory: nil,
      tty: false,
      yieldTimeMS: 100,
      timeoutMS: 5_000,
      clientRequestID: "req-exec-1"
    )
    do {
      _ = try await application.serviceDirectExecCommand(request, deadline: deadline)
      XCTFail("Expected approval_required")
    } catch let error as BridgeMCPQueryError {
      guard case .approvalRequired(let approvalID) = error else {
        return XCTFail("Expected approvalRequired, got \(error)")
      }
      let approved = await application.approvals.approve(approvalID: approvalID)
      XCTAssertTrue(approved)
    }
    let receipt = try await application.serviceDirectExecCommand(request, deadline: deadline)
    XCTAssertEqual(receipt.status, "ended")
    XCTAssertEqual(receipt.exitCode, 0)
    await application.directCommands.cancelAll()
  }

  func testAutoApprovalModeSkipsDirectApprovalEntirely() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let target = fixture.root.appending(path: "AutoApprovedFile.txt")

    let request = MCPDirectWriteRequest(
      projectID: fixture.project.id.rawValue,
      relativePath: "AutoApprovedFile.txt",
      mode: "create",
      content: "auto",
      expectedSHA256: nil,
      createParents: false,
      clientRequestID: "req-auto-1"
    )
    // Auto mode: every call succeeds without creating any pending approval.
    let first = try await application.serviceDirectWriteFile(request, deadline: deadline)
    XCTAssertEqual(first.relativePath, "AutoApprovedFile.txt")
    let pending = await application.approvals.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
    let second = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: "AutoApprovedFile.txt",
        mode: "replace",
        content: "auto",
        expectedSHA256: nil,
        createParents: false,
        clientRequestID: "req-auto-1"
      ),
      deadline: deadline
    )
    XCTAssertEqual(second.relativePath, "AutoApprovedFile.txt")
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "auto")
  }

  func testAutoApprovalModeAllowsElevatedCommandWithoutApproval() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .registered,
      workspaceCommands: [
        try ServiceWorkspaceCommand(
          id: "wcmd-auto-deploy",
          name: "Auto Deploy",
          executable: "/bin/echo",
          arguments: ["auto-deploying"],
          requiresNetwork: false,
          risk: .elevated
        )
      ],
      projectID: fixture.project.id
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let request = MCPDirectExecRequest(
      projectID: fixture.project.id.rawValue,
      commandID: "wcmd-auto-deploy",
      argv: [],
      workingDirectory: nil,
      tty: false,
      yieldTimeMS: 100,
      timeoutMS: 5_000,
      clientRequestID: "req-auto-exec-1"
    )
    let receipt = try await application.serviceDirectExecCommand(request, deadline: deadline)
    XCTAssertEqual(receipt.status, "ended")
    XCTAssertEqual(receipt.exitCode, 0)
    let pending = await application.approvals.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
    await application.directCommands.cancelAll()
  }
}
