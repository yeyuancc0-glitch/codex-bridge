import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeVerification

final class VerificationAuthorizationStoreTests: XCTestCase {
  func testAuthorizationSurvivesRestartAndIsConsumedBeforeOneExecution() async throws {
    let fixture = try AuthorizationFixture(label: "restart")
    defer { fixture.remove() }
    let marker = "authorized-marker"
    let command = try VerificationCommand(executable: "/usr/bin/touch", arguments: [marker])
    let project = try fixture.project(commands: [command])
    let issuedAt = Date()
    let clock = TestAuthorizationClock(issuedAt)
    let issuer = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let handle = try await issuer.issue(
      taskID: "task-one",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 2
    )

    let reopened = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    clock.set(issuedAt.addingTimeInterval(1))
    let result = try await VerificationRunner().run(
      taskID: "task-one",
      generation: 2,
      project: project,
      workingDirectory: project.primaryRoot,
      command: .identifier(VerificationCommandIdentifier(command: command)),
      required: true,
      authorization: handle,
      authorizationStore: reopened
    )

    XCTAssertEqual(result.status, .passed)
    XCTAssertTrue(fixture.exists(marker))
    clock.set(issuedAt.addingTimeInterval(2))
    do {
      _ = try await VerificationRunner().run(
        taskID: "task-one",
        generation: 2,
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        required: true,
        authorization: handle,
        authorizationStore: reopened
      )
      XCTFail("Expected replay rejection")
    } catch {
      XCTAssertEqual(error as? VerificationAuthorizationError, .alreadyConsumed)
    }
  }

  func testWrongTaskProjectCommandRootAndGenerationAllFailClosed() async throws {
    let fixture = try AuthorizationFixture(label: "binding")
    defer { fixture.remove() }
    let secondRoot = fixture.url.appending(path: "worktree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
    let commands = [
      try VerificationCommand(executable: "/usr/bin/true"),
      try VerificationCommand(executable: "/usr/bin/false"),
    ]
    let project = try fixture.project(commands: commands, worktrees: [secondRoot])
    let otherProject = try fixture.project(id: "project-two", commands: commands)
    let now = Date()
    let clock = TestAuthorizationClock(now)
    let store = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)

    let bindings: [(String, RegisteredProject, RegisteredRoot, Int64, Int)] = [
      ("wrong-task", project, project.primaryRoot, 1, 0),
      ("task", otherProject, otherProject.primaryRoot, 1, 0),
      ("task", project, project.primaryRoot, 1, 1),
      ("task", project, project.worktreeRoots[0], 1, 0),
      ("task", project, project.primaryRoot, 2, 0),
    ]

    for (taskID, runProject, root, generation, commandIndex) in bindings {
      let handle = try await store.issue(
        taskID: "task",
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        generation: 1
      )
      clock.set(now.addingTimeInterval(1))
      do {
        _ = try await VerificationRunner().run(
          taskID: taskID,
          generation: generation,
          project: runProject,
          workingDirectory: root,
          command: .index(commandIndex),
          required: true,
          authorization: handle,
          authorizationStore: store
        )
        XCTFail("Expected binding mismatch")
      } catch {
        XCTAssertEqual(error as? VerificationAuthorizationError, .bindingMismatch)
      }
    }
  }

  func testExpiredAndFutureAuthorizationAreRejectedWithoutExecution() async throws {
    let fixture = try AuthorizationFixture(label: "expiry")
    defer { fixture.remove() }
    let command = try VerificationCommand(
      executable: "/usr/bin/touch",
      arguments: ["must-not-run"]
    )
    let project = try fixture.project(commands: [command])
    let issuedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let clock = TestAuthorizationClock(issuedAt)
    let store = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)

    for invalidNow in [issuedAt.addingTimeInterval(-1), issuedAt.addingTimeInterval(11)] {
      clock.set(issuedAt)
      let handle = try await store.issue(
        taskID: "task-expiry-\(invalidNow.timeIntervalSince1970)",
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        generation: 1,
        validFor: 10
      )
      clock.set(invalidNow)
      do {
        _ = try await VerificationRunner().run(
          taskID: "task-expiry-\(invalidNow.timeIntervalSince1970)",
          generation: 1,
          project: project,
          workingDirectory: project.primaryRoot,
          command: .index(0),
          required: true,
          authorization: handle,
          authorizationStore: store
        )
        XCTFail("Expected time-bound authorization rejection")
      } catch {
        XCTAssertEqual(error as? VerificationAuthorizationError, .expired)
      }
    }
    XCTAssertFalse(fixture.exists("must-not-run"))
  }

  func testConcurrentConsumptionAllowsExactlyOneRun() async throws {
    let fixture = try AuthorizationFixture(label: "concurrent")
    defer { fixture.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try fixture.project(commands: [command])
    let now = Date()
    let clock = TestAuthorizationClock(now)
    let issuer = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let handle = try await issuer.issue(
      taskID: "task-concurrent",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 4
    )
    let firstStore = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let secondStore = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let stores = [firstStore, secondStore]
    clock.set(now.addingTimeInterval(1))

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for store in stores {
        group.addTask {
          do {
            let result = try await VerificationRunner().run(
              taskID: "task-concurrent",
              generation: 4,
              project: project,
              workingDirectory: project.primaryRoot,
              command: .index(0),
              required: true,
              authorization: handle,
              authorizationStore: store
            )
            return result.status == .passed
          } catch {
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }

    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
  }

  func testPersistentRecordContainsNoPathArgvOrRawOutputAndTamperingFailsClosed() async throws {
    let fixture = try AuthorizationFixture(label: "redaction")
    defer { fixture.remove() }
    let sensitiveArgument = "sensitive-argument-never-persist"
    let command = try VerificationCommand(
      executable: "/usr/bin/printf",
      arguments: [sensitiveArgument]
    )
    let project = try fixture.project(commands: [command])
    let store = try VerificationAuthorizationStore(path: fixture.storePath)
    let handle = try await store.issue(
      taskID: "task-redacted",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 1
    )
    let stored = try Data(contentsOf: URL(fileURLWithPath: fixture.storePath))
    let text = String(decoding: stored, as: UTF8.self)
    let envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: stored) as? [String: Any]
    )
    let encodedPayload = try XCTUnwrap(envelope["payload"] as? String)
    let payload = try XCTUnwrap(Data(base64Encoded: encodedPayload))
    let payloadText = String(decoding: payload, as: UTF8.self)
    let permissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fixture.storePath)[.posixPermissions]
        as? NSNumber
    )

    for forbidden in [
      project.primaryRoot.canonicalPath, command.executable, sensitiveArgument, handle.nonce,
    ] {
      XCTAssertFalse(text.contains(forbidden))
      XCTAssertFalse(payloadText.contains(forbidden))
    }
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    var tampered = stored
    tampered[tampered.startIndex] ^= 1
    try tampered.write(to: URL(fileURLWithPath: fixture.storePath), options: .atomic)
    XCTAssertThrowsError(try VerificationAuthorizationStore(path: fixture.storePath)) { error in
      XCTAssertEqual(error as? VerificationAuthorizationError, .corruptStore)
    }
  }

  func testInvalidLifetimeAndSymlinkStoreFailClosed() async throws {
    let fixture = try AuthorizationFixture(label: "invalid")
    defer { fixture.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try fixture.project(commands: [command])
    let store = try VerificationAuthorizationStore(path: fixture.storePath)
    do {
      _ = try await store.issue(
        taskID: "task",
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        generation: 1,
        validFor: .infinity
      )
      XCTFail("Expected invalid lifetime")
    } catch {
      XCTAssertEqual(error as? VerificationAuthorizationError, .invalidArgument("lifetime"))
    }

    let target = fixture.url.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    let symlink = fixture.url.appending(path: "authorization-link.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    XCTAssertThrowsError(try VerificationAuthorizationStore(path: symlink.path)) { error in
      XCTAssertEqual(error as? VerificationAuthorizationError, .storeUnavailable)
    }
  }

  func testExpiredRecordsArePrunedWhenIssuingCurrentAuthorization() async throws {
    let fixture = try AuthorizationFixture(label: "pruning")
    defer { fixture.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try fixture.project(commands: [command])
    let initial = Date(timeIntervalSince1970: 2_000_000_000)
    let clock = TestAuthorizationClock(initial)
    let store = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    for index in 0..<2 {
      _ = try await store.issue(
        taskID: "expired-\(index)",
        project: project,
        workingDirectory: project.primaryRoot,
        command: .index(0),
        generation: 1,
        validFor: 1
      )
    }

    clock.set(initial.addingTimeInterval(2))
    let current = try await store.issue(
      taskID: "current",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 1
    )
    XCTAssertEqual(current.nonce.count, 64)
    let stored = try Data(contentsOf: URL(fileURLWithPath: fixture.storePath))
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    let encodedPayload = try XCTUnwrap(envelope["payload"] as? String)
    let payload = try XCTUnwrap(Data(base64Encoded: encodedPayload))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let records = try XCTUnwrap(object["records"] as? [[String: Any]])
    XCTAssertEqual(records.count, 1)
  }

  func testRetentionCleanupBlocksOnActiveAuthorizationThenRemovesOnlyTargetRecords() async throws {
    let fixture = try AuthorizationFixture(label: "retention")
    defer { fixture.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try fixture.project(commands: [command])
    let issuedAt = Date(timeIntervalSince1970: 2_100_000_000)
    let clock = TestAuthorizationClock(issuedAt)
    let issuer = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let consumed = try await issuer.issue(
      taskID: "task-retention",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 1,
      validFor: 10
    )
    _ = try await issuer.issue(
      taskID: "task-retention",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 2,
      validFor: 10
    )
    let other = try await issuer.issue(
      taskID: "task-other",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 1,
      validFor: 100
    )
    clock.set(issuedAt.addingTimeInterval(1))
    _ = try await VerificationRunner().run(
      taskID: "task-retention",
      generation: 1,
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: consumed,
      authorizationStore: issuer
    )
    let beforeBlockedCleanup = try Data(contentsOf: URL(fileURLWithPath: fixture.storePath))

    let second = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let blocked = try await second.removeRecordsForRetention(taskID: "task-retention")
    XCTAssertEqual(blocked, .blockedByActiveAuthorization)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: fixture.storePath)),
      beforeBlockedCleanup
    )

    clock.set(issuedAt.addingTimeInterval(11))
    let removed = try await issuer.removeRecordsForRetention(taskID: "task-retention")
    XCTAssertEqual(removed, .removed(2))
    let restarted = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    let repeated = try await restarted.removeRecordsForRetention(taskID: "task-retention")
    XCTAssertEqual(repeated, .removed(0))
    clock.set(issuedAt.addingTimeInterval(12))
    let otherResult = try await VerificationRunner().run(
      taskID: "task-other",
      generation: 1,
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      required: true,
      authorization: other,
      authorizationStore: restarted
    )
    XCTAssertEqual(otherResult.status, .passed)
  }

  func testRetentionCleanupConservativelyBlocksFutureUnconsumedAuthorization() async throws {
    let fixture = try AuthorizationFixture(label: "retention-future")
    defer { fixture.remove() }
    let command = try VerificationCommand(executable: "/usr/bin/true")
    let project = try fixture.project(commands: [command])
    let issuedAt = Date(timeIntervalSince1970: 2_100_000_100)
    let clock = TestAuthorizationClock(issuedAt)
    let store = try VerificationAuthorizationStore(path: fixture.storePath, clock: clock)
    _ = try await store.issue(
      taskID: "task-future",
      project: project,
      workingDirectory: project.primaryRoot,
      command: .index(0),
      generation: 1,
      validFor: 10
    )

    clock.set(issuedAt.addingTimeInterval(-1))
    let blocked = try await store.removeRecordsForRetention(taskID: "task-future")
    XCTAssertEqual(blocked, .blockedByActiveAuthorization)
  }
}

private final class TestAuthorizationClock: VerificationAuthorizationClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func set(_ value: Date) {
    lock.withLock { self.value = value }
  }
}

private struct AuthorizationFixture {
  let url: URL
  let storePath: String

  init(label: String) throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "bridge-verification-authorization-\(label)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    storePath = url.appending(path: "authorization.json").path
  }

  func project(
    id: String = "project-one",
    commands: [VerificationCommand],
    worktrees: [URL] = []
  ) throws -> RegisteredProject {
    let root = try RegisteredRoot(capturing: url)
    return RegisteredProject(
      id: ProjectID(rawValue: id),
      name: "Authorization Fixture",
      primaryRoot: root,
      repositoryRoot: root,
      worktreeRoots: try worktrees.map(RegisteredRoot.init(capturing:)),
      accessPolicy: .init(),
      verificationCommands: commands,
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: url.appending(path: name).path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
