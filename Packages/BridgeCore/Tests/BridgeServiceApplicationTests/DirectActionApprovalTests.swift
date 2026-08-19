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
    var pollDeadline = Date().addingTimeInterval(10)
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
  }
}
