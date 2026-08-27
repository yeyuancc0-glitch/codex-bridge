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
    let retryConsumed = await center.consume(payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(retryConsumed)
    let retryID = await center.request(
      projectID: "prj-1",
      kind: .fileWrite,
      summary: "Write",
      payloadDigest: "digest-a",
      clientRequestID: "req-1"
    )
    XCTAssertNotEqual(retryID, id)
    XCTAssertTrue(retryID.hasPrefix("denied-"))
    let approved = await center.approve(approvalID: retryID)
    let pending = await center.pendingApprovals()
    let consumedAfterRetry = await center.consume(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    let denialActive = await center.denialIsActive(
      payloadDigest: "digest-a", clientRequestID: "req-1")
    XCTAssertFalse(approved)
    XCTAssertTrue(pending.isEmpty)
    XCTAssertFalse(consumedAfterRetry)
    XCTAssertTrue(denialActive)
  }

  func testApprovedGrantExpiresWithoutBeingConsumed() async {
    let center = DirectActionApprovalCenter(approvalLifetime: 0.1)
    let id = await center.request(
      projectID: "prj-1",
      kind: .command,
      summary: "Run",
      payloadDigest: "digest-grant",
      clientRequestID: nil
    )
    let approved = await center.approve(approvalID: id)
    try? await Task.sleep(for: .milliseconds(150))
    let consumed = await center.consume(payloadDigest: "digest-grant", clientRequestID: nil)
    XCTAssertTrue(approved)
    XCTAssertFalse(consumed)
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
      XCTFail("Expected approval_denied after denial")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .approvalDenied)
    }
    let target = fixture.root.appending(path: "DeniedFile.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testDirectExecCommandRequiresApprovalForElevatedCommand() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .safe,
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
      let pending = await application.approvals.pendingApprovals()
      XCTAssertTrue(
        pending.first(where: { $0.approvalID == approvalID })?.summary
          .contains("/bin/echo deploying") == true
      )
      let approved = await application.approvals.approve(approvalID: approvalID)
      XCTAssertTrue(approved)
    }
    let receipt = try await application.serviceDirectExecCommand(request, deadline: deadline)
    XCTAssertEqual(receipt.status, "ended")
    XCTAssertEqual(receipt.exitCode, 0)
    await application.directCommands.cancelAll()
  }

  func testDirectExecDeadlineCancelsLaunchedProcessAndReleasesWorkspaceLease() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let script = fixture.root.appending(path: "Scripts/long-running.sh")
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))

    let task = Task {
      try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          argv: ["Scripts/long-running.sh"],
          yieldTimeMS: 60_000,
          timeoutMS: 60_000,
          clientRequestID: "req-deadline-cleanup"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(1))
      )
    }
    let launchDeadline = Date().addingTimeInterval(5)
    var sessionID: String?
    while Date() < launchDeadline {
      if let session = await application.directCommands.activeSession(projectID: fixture.project.id)
      {
        sessionID = session.sessionID
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(sessionID)

    do {
      _ = try await task.value
      XCTFail("Expected the service deadline to cancel the direct command")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .timeout)
    }

    let cleanupDeadline = Date().addingTimeInterval(5)
    while Date() < cleanupDeadline {
      guard await application.directCommands.isBusy(projectID: fixture.project.id) else { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let isBusy = await application.directCommands.isBusy(projectID: fixture.project.id)
    XCTAssertFalse(isBusy)
    if let sessionID {
      let session = await application.directCommands.snapshot(sessionID: sessionID)
      XCTAssertNotEqual(session?.status, "running")
    }
    await application.directCommands.cancelAll()
  }

  func testDirectExecCancellationDoesNotLeaveHiddenSessionOrLease() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let script = fixture.root.appending(path: "Scripts/long-running.sh")
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))

    let task = Task {
      try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          argv: ["Scripts/long-running.sh"],
          yieldTimeMS: 60_000,
          timeoutMS: 60_000,
          clientRequestID: "req-cancellation-cleanup"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(30))
      )
    }
    let launchDeadline = Date().addingTimeInterval(5)
    var sessionID: String?
    while Date() < launchDeadline {
      if let session = await application.directCommands.activeSession(projectID: fixture.project.id)
      {
        sessionID = session.sessionID
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(sessionID)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected task cancellation")
    } catch is CancellationError {
      // The service must terminate the launched process before propagating cancellation.
    }

    let cleanupDeadline = Date().addingTimeInterval(5)
    while Date() < cleanupDeadline {
      guard await application.directCommands.isBusy(projectID: fixture.project.id) else { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let isBusy = await application.directCommands.isBusy(projectID: fixture.project.id)
    XCTAssertFalse(isBusy)
    if let sessionID {
      let session = await application.directCommands.snapshot(sessionID: sessionID)
      XCTAssertNotEqual(session?.status, "running")
    }
    await application.directCommands.cancelAll()
  }

  func testRequireApprovalCoversEveryAllowedDirectMutationEntryPoint() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateAccessPolicy(
      ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed),
      projectID: fixture.project.id
    )
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .full,
      workspaceCommands: [],
      projectID: fixture.project.id
    )
    let skill = fixture.root.appending(
      path: "skills/require-approval", directoryHint: .isDirectory)
    let scripts = skill.appending(path: "scripts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let skillDocument = """
      ---
      name: require-approval
      description: approval fixture
      actions:
        - name: run
          script: scripts/run.sh
          requires_network: false
      ---
      """
    try Data(skillDocument.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    try Data("#!/bin/sh\necho should-not-run\n".utf8)
      .write(to: scripts.appendingPathComponent("run.sh"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scripts.appendingPathComponent("run.sh").path)

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .require, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    func expectApproval(_ operation: () async throws -> Void) async throws {
      do {
        try await operation()
        XCTFail("Expected approval_required")
      } catch let error as BridgeMCPQueryError {
        guard case .approvalRequired = error else {
          XCTFail("Expected approvalRequired, got \(error)")
          return
        }
      }
    }

    try await expectApproval {
      _ = try await application.serviceDirectWriteFile(
        MCPDirectWriteRequest(
          projectID: fixture.project.id.rawValue,
          relativePath: "RequireWrite.txt",
          mode: "create",
          content: "write",
          clientRequestID: "require-write"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceDirectEditFile(
        MCPDirectEditRequest(
          projectID: fixture.project.id.rawValue,
          relativePath: "RequireEdit.txt",
          expectedSHA256: "missing",
          oldText: "old",
          newText: "new",
          expectedReplacements: 1,
          clientRequestID: "require-edit"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceDirectApplyPatch(
        MCPDirectPatchRequest(
          projectID: fixture.project.id.rawValue,
          patch: "*** Begin Patch\n*** Add File: RequirePatch.txt\n+patch\n*** End Patch",
          clientRequestID: "require-patch"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceDirectManagePath(
        MCPDirectManagePathRequest(
          projectID: fixture.project.id.rawValue,
          action: "create_directory",
          relativePath: "RequireDirectory",
          clientRequestID: "require-path"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          argv: ["echo", "should-not-run"],
          yieldTimeMS: 20,
          timeoutMS: 5_000,
          clientRequestID: "require-command"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceDirectGitCommit(
        MCPDirectGitCommitRequest(
          projectID: fixture.project.id.rawValue,
          message: "approval required",
          clientRequestID: "require-git"
        ),
        deadline: deadline
      )
    }
    try await expectApproval {
      _ = try await application.serviceRunSkillAction(
        MCPRunSkillActionRequest(
          skillName: "require-approval",
          actionName: "run",
          projectID: fixture.project.id.rawValue,
          yieldTimeMS: 20,
          timeoutMS: 5_000,
          clientRequestID: "require-skill"
        ),
        deadline: deadline
      )
    }

    let pending = await application.approvals.pendingApprovals()
    XCTAssertEqual(pending.count, 7)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("RequireWrite.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("RequirePatch.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("RequireDirectory").path))
    await application.directCommands.cancelAll()
  }

  func testRequireApprovalDoesNotOverrideProjectWriteDenial() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateAccessPolicy(
      ProjectAccessPolicy(read: .allowed, write: .denied, network: .allowed),
      projectID: fixture.project.id
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .require, deadline: ContinuousClock.now.advanced(by: .seconds(30)))

    do {
      _ = try await application.serviceDirectWriteFile(
        MCPDirectWriteRequest(
          projectID: fixture.project.id.rawValue,
          relativePath: "DeniedBeforeApproval.txt",
          mode: "create",
          content: "denied"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected write_not_allowed")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .writeNotAllowed)
    }
    let pending = await application.approvals.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
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
      directCommandMode: .safe,
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

  func testEditRevisionConflictReturnsCurrentSHAAndBoundedExcerpt() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let target = "ConflictFile.txt"
    let original = Data("line1\nline2\nline3\n".utf8)
    let originalSHA = SecureFileRevision.digest(of: original).sha256
    _ = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: target,
        mode: "create",
        content: "line1\nline2\nline3\n",
        expectedSHA256: nil,
        createParents: false,
        clientRequestID: "req-conflict-write"
      ),
      deadline: deadline
    )
    // Simulate an external writer that changed the file since the caller read it.
    let changed = Data("line1\nCHANGED\nline3\n".utf8)
    try changed.write(to: fixture.root.appending(path: target))
    do {
      _ = try await application.serviceDirectEditFile(
        MCPDirectEditRequest(
          projectID: fixture.project.id.rawValue,
          relativePath: target,
          expectedSHA256: originalSHA,
          oldText: "line2",
          newText: "replacement",
          expectedReplacements: 1,
          clientRequestID: "req-conflict-edit"
        ),
        deadline: deadline
      )
      XCTFail("Expected revision conflict")
    } catch let error as BridgeMCPQueryError {
      guard case .revisionConflict(let detail) = error else {
        return XCTFail("Expected revisionConflict, got \(error)")
      }
      XCTAssertEqual(detail.relativePath, target)
      XCTAssertEqual(detail.currentSHA256, SecureFileRevision.digest(of: changed).sha256)
      XCTAssertTrue(detail.changedSinceRevision)
      XCTAssertTrue(detail.addedLines.contains("CHANGED"))
    }
  }

  func testSafeModeRunsProjectLocalScriptEndToEnd() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let scripts = fixture.root.appending(path: "Scripts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let script = scripts.appending(path: "hello.sh")
    try Data("#!/bin/sh\necho hello-from-script\n".utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path)

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let receipt = try await application.serviceDirectExecCommand(
      MCPDirectExecRequest(
        projectID: fixture.project.id.rawValue,
        commandID: nil,
        argv: ["Scripts/hello.sh"],
        workingDirectory: nil,
        tty: false,
        yieldTimeMS: 50,
        timeoutMS: 5_000,
        clientRequestID: "req-script"
      ),
      deadline: deadline
    )
    var sessionID = receipt.sessionID
    var finalOutput = receipt.output
    let pollDeadline = Date().addingTimeInterval(10)
    while Date() < pollDeadline {
      let output = try await application.serviceDirectReadCommand(
        sessionID: sessionID,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      sessionID = output.sessionID
      finalOutput = output
      if output.status == "ended" || output.status == "cancelled" || output.status == "timed_out" {
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let ended = try XCTUnwrap(finalOutput)
    XCTAssertEqual(ended.status, "ended")
    XCTAssertEqual(ended.exitCode, 0)
    XCTAssertTrue(ended.tail.contains("hello-from-script"))
    await application.directCommands.cancelAll()
  }

  func testSafeModeRunsBareBinaryViaTrustedPathAndNormalizesDotWorkingDirectory() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let receipt = try await application.serviceDirectExecCommand(
      MCPDirectExecRequest(
        projectID: fixture.project.id.rawValue,
        commandID: nil,
        argv: ["pwd"],
        workingDirectory: ".",
        tty: false,
        yieldTimeMS: 50,
        timeoutMS: 5_000,
        clientRequestID: "req-bare-pwd"
      ),
      deadline: deadline
    )
    var sessionID = receipt.sessionID
    var finalOutput = receipt.output
    let pollDeadline = Date().addingTimeInterval(10)
    while Date() < pollDeadline {
      let output = try await application.serviceDirectReadCommand(
        sessionID: sessionID,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      sessionID = output.sessionID
      finalOutput = output
      if output.status == "ended" || output.status == "cancelled" || output.status == "timed_out" {
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let ended = try XCTUnwrap(finalOutput)
    XCTAssertEqual(ended.status, "ended")
    XCTAssertEqual(ended.exitCode, 0)
    XCTAssertFalse(ended.tail.isEmpty)
    await application.directCommands.cancelAll()
  }

  func testSafeModeRunsBareGitStatusThroughSystemBuiltIn() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let initialize = Process()
    initialize.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    initialize.arguments = ["init", "--quiet", fixture.root.path]
    try initialize.run()
    initialize.waitUntilExit()
    XCTAssertEqual(initialize.terminationStatus, 0)

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let receipt = try await application.serviceDirectExecCommand(
      MCPDirectExecRequest(
        projectID: fixture.project.id.rawValue,
        commandID: nil,
        argv: ["git", "status", "--short"],
        workingDirectory: nil,
        tty: false,
        yieldTimeMS: 50,
        timeoutMS: 5_000,
        clientRequestID: "req-bare-git-status"
      ),
      deadline: deadline
    )
    var output = try XCTUnwrap(receipt.output)
    while output.status == "running" && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      output = try await application.serviceDirectReadCommand(
        sessionID: receipt.sessionID,
        deadline: deadline
      )
    }

    XCTAssertEqual(output.status, "ended")
    XCTAssertEqual(output.exitCode, 0)
    await application.directCommands.cancelAll()
  }

  func testDirectExecutablePathEscapeReturnsPathDenied() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )

    do {
      _ = try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          commandID: nil,
          argv: ["../outside.sh"],
          workingDirectory: nil,
          tty: false,
          yieldTimeMS: 0,
          timeoutMS: 5_000,
          clientRequestID: "req-escaped-executable"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected path denial")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .pathDenied)
    }
  }

  func testMissingBareExecutableReturnsProcessLaunchFailedInFullMode() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .full,
      workspaceCommands: [],
      projectID: fixture.project.id
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))

    do {
      _ = try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          commandID: nil,
          argv: ["codex-bridge-command-that-does-not-exist"],
          workingDirectory: nil,
          tty: false,
          yieldTimeMS: 0,
          timeoutMS: 5_000,
          clientRequestID: "req-missing-executable"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected process launch failure")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .processLaunchFailed)
    }
  }

  func testRegisteredCommandBindsWorkingDirectoryAndRejectsSymlinkCwd() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let scripts = fixture.root.appending(path: "scripts", directoryHint: .isDirectory)
    let outside = fixture.root.deletingLastPathComponent()
      .appending(path: "direct-cwd-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: outside) }
    let escape = fixture.root.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .safe,
      workspaceCommands: [
        try ServiceWorkspaceCommand(
          id: "wcmd-cwd",
          name: "Write in bound cwd",
          executable: "/bin/sh",
          arguments: ["-c", "printf bound > cwd-marker.txt"],
          workingDirectory: "scripts"
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let receipt = try await application.serviceDirectExecCommand(
      MCPDirectExecRequest(
        projectID: fixture.project.id.rawValue,
        commandID: "wcmd-cwd",
        argv: [],
        workingDirectory: "escape",
        tty: false,
        yieldTimeMS: 100,
        timeoutMS: 5_000,
        clientRequestID: "req-bound-cwd"
      ),
      deadline: deadline
    )
    var output = try XCTUnwrap(receipt.output)
    while output.status == "running" && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      output = try await application.serviceDirectReadCommand(
        sessionID: receipt.sessionID,
        deadline: deadline
      )
    }
    XCTAssertEqual(output.status, "ended")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: scripts.appending(path: "cwd-marker.txt").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appending(path: "cwd-marker.txt").path)
    )

    do {
      _ = try await application.serviceDirectExecCommand(
        MCPDirectExecRequest(
          projectID: fixture.project.id.rawValue,
          commandID: nil,
          argv: ["pwd"],
          workingDirectory: "escape",
          tty: false,
          yieldTimeMS: 20,
          timeoutMS: 5_000,
          clientRequestID: "req-escape-cwd"
        ),
        deadline: deadline
      )
      XCTFail("Expected symlink cwd rejection")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .pathDenied)
    }
    await application.directCommands.cancelAll()
  }

  func testReadProjectFileSupportsLargeLineCountPages() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let content = (1...400).map { "line\($0)" }.joined(separator: "\n")
    try Data(content.utf8).write(to: fixture.root.appending(path: "big.txt"))
    let page = try await application.serviceReadProjectFile(
      projectID: fixture.project.id.rawValue,
      relativePath: "big.txt",
      startLine: 1,
      lineCount: 500,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )
    XCTAssertEqual(page.endLine, 400)
    XCTAssertNil(page.nextStartLine)
    XCTAssertFalse(page.truncated)
  }

  func testApplyPatchAddsFileEndToEnd() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let patch = """
      *** Begin Patch
      *** Add File: Sources/Patched.swift
      +func patched() {}
      *** End Patch
      """
    let receipt = try await application.serviceDirectApplyPatch(
      MCPDirectPatchRequest(
        projectID: fixture.project.id.rawValue,
        patch: patch,
        clientRequestID: "req-patch-1"
      ),
      deadline: deadline
    )
    XCTAssertEqual(receipt.operations.map(\.relativePath), ["Sources/Patched.swift"])
    let content = try String(contentsOf: fixture.root.appending(path: "Sources/Patched.swift"))
    XCTAssertTrue(content.contains("func patched() {}"))
  }

  func testInvalidPatchReleasesWorkspaceLease() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    do {
      _ = try await application.serviceDirectApplyPatch(
        MCPDirectPatchRequest(
          projectID: fixture.project.id.rawValue,
          patch: "not a project patch",
          clientRequestID: "req-invalid-patch"
        ),
        deadline: deadline
      )
      XCTFail("Expected invalid patch")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .invalidPatchSyntax)
    }

    let receipt = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: "AfterInvalidPatch.txt",
        mode: "create",
        content: "lease released",
        clientRequestID: "req-after-invalid-patch"
      ),
      deadline: deadline
    )
    XCTAssertEqual(receipt.relativePath, "AfterInvalidPatch.txt")
  }

  func testDirectGitCommitCreatesLocalCommit() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))

    let initRepo = Process()
    initRepo.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    initRepo.arguments = ["init"]
    initRepo.currentDirectoryURL = fixture.root
    initRepo.standardOutput = FileHandle.nullDevice
    initRepo.standardError = FileHandle.nullDevice
    try initRepo.run()
    initRepo.waitUntilExit()

    let config = Process()
    config.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    config.arguments = ["config", "user.email", "bridge@example.com"]
    config.currentDirectoryURL = fixture.root
    config.standardOutput = FileHandle.nullDevice
    config.standardError = FileHandle.nullDevice
    try config.run()
    config.waitUntilExit()
    let configName = Process()
    configName.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    configName.arguments = ["config", "user.name", "Codex Bridge"]
    configName.currentDirectoryURL = fixture.root
    configName.standardOutput = FileHandle.nullDevice
    configName.standardError = FileHandle.nullDevice
    try configName.run()
    configName.waitUntilExit()

    let unrelated = fixture.root.appending(path: "UnrelatedStaged.txt")
    try Data("keep staged\n".utf8).write(to: unrelated)
    let stageUnrelated = Process()
    stageUnrelated.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    stageUnrelated.arguments = ["add", "--", unrelated.lastPathComponent]
    stageUnrelated.currentDirectoryURL = fixture.root
    stageUnrelated.standardOutput = FileHandle.nullDevice
    stageUnrelated.standardError = FileHandle.nullDevice
    try stageUnrelated.run()
    stageUnrelated.waitUntilExit()
    XCTAssertEqual(stageUnrelated.terminationStatus, 0)

    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    _ = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: "CommittedFile.txt",
        mode: "create",
        content: "hello\n",
        expectedSHA256: nil,
        createParents: false,
        clientRequestID: "req-commit-write"
      ),
      deadline: deadline
    )
    let receipt = try await application.serviceDirectGitCommit(
      MCPDirectGitCommitRequest(
        projectID: fixture.project.id.rawValue,
        message: "feat: add committed file",
        files: ["CommittedFile.txt"],
        clientRequestID: "req-commit"
      ),
      deadline: deadline
    )
    XCTAssertEqual(receipt.exitCode, 0)
    XCTAssertNotNil(receipt.commitHash)
    XCTAssertEqual(receipt.commitHash?.count, 40)
    XCTAssertEqual(receipt.changedFiles, ["CommittedFile.txt"])

    // The file must actually be committed (working tree clean for it).
    let status = Process()
    status.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    status.arguments = ["status", "--porcelain"]
    status.currentDirectoryURL = fixture.root
    let pipe = Pipe()
    status.standardOutput = pipe
    status.standardError = FileHandle.nullDevice
    try status.run()
    status.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertFalse(output.contains("CommittedFile.txt"), "file should be committed: \(output)")
    XCTAssertTrue(
      output.contains("UnrelatedStaged.txt"), "unrelated staged file must remain: \(output)")

    let staged = Process()
    staged.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    staged.arguments = ["diff", "--cached", "--name-only"]
    staged.currentDirectoryURL = fixture.root
    let stagedPipe = Pipe()
    staged.standardOutput = stagedPipe
    staged.standardError = FileHandle.nullDevice
    try staged.run()
    staged.waitUntilExit()
    let stagedOutput = String(
      decoding: stagedPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(
      stagedOutput.trimmingCharacters(in: .whitespacesAndNewlines), "UnrelatedStaged.txt")

    let hook = fixture.root.appending(path: ".git/hooks/pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    _ = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: "FailedCommit.txt",
        mode: "create",
        content: "failure\n",
        expectedSHA256: nil,
        createParents: false,
        clientRequestID: "req-failed-commit-write"
      ),
      deadline: deadline
    )
    do {
      _ = try await application.serviceDirectGitCommit(
        MCPDirectGitCommitRequest(
          projectID: fixture.project.id.rawValue,
          message: "should fail hook",
          files: ["FailedCommit.txt"]
        ),
        deadline: deadline
      )
      XCTFail("Expected pre-commit failure")
    } catch let error as BridgeMCPQueryError {
      guard case .gitOperationFailed = error else {
        return XCTFail("Expected gitOperationFailed, got \(error)")
      }
    }
    let stagedAfterFailure = Process()
    stagedAfterFailure.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    stagedAfterFailure.arguments = ["diff", "--cached", "--name-only"]
    stagedAfterFailure.currentDirectoryURL = fixture.root
    let stagedAfterFailurePipe = Pipe()
    stagedAfterFailure.standardOutput = stagedAfterFailurePipe
    stagedAfterFailure.standardError = FileHandle.nullDevice
    try stagedAfterFailure.run()
    stagedAfterFailure.waitUntilExit()
    let stagedAfterFailureOutput = String(
      decoding: stagedAfterFailurePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(
      stagedAfterFailureOutput.trimmingCharacters(in: .whitespacesAndNewlines),
      "UnrelatedStaged.txt"
    )

    try Data("TOKEN=secret\n".utf8).write(to: fixture.root.appending(path: ".env"))
    do {
      _ = try await application.serviceDirectGitCommit(
        MCPDirectGitCommitRequest(
          projectID: fixture.project.id.rawValue,
          message: "should reject env",
          files: [".env"]
        ),
        deadline: deadline
      )
      XCTFail("Expected sensitive path rejection")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .contractRejected)
    }

    try Data(#"api_key = "secret-value"\n"#.utf8)
      .write(to: fixture.root.appending(path: "safe.txt"))
    do {
      _ = try await application.serviceDirectGitCommit(
        MCPDirectGitCommitRequest(
          projectID: fixture.project.id.rawValue,
          message: "should reject secret",
          files: ["safe.txt"]
        ),
        deadline: deadline
      )
      XCTFail("Expected sensitive content rejection")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .unsafeContentDetected)
    }

    do {
      _ = try await application.serviceDirectGitCommit(
        MCPDirectGitCommitRequest(
          projectID: fixture.project.id.rawValue,
          message: "should reject sensitive all-files commit",
          files: []
        ),
        deadline: deadline
      )
      XCTFail("Expected all-files sensitive path rejection")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .contractRejected)
    }
  }
}
