import BridgeDomain
import BridgePipeline
import BridgeProjects
import BridgeSecurity
import BridgeVerification
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopTaskPipelineTests: XCTestCase {
  func testProductionVerificationAdapterCannotClaimExecutionWithoutOneTimeAuthorization()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-desktop-pipeline-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let root = try RegisteredRoot(capturing: directory)
    let command = try VerificationCommand(
      executable: "/usr/bin/xcrun",
      arguments: ["swift", "test"]
    )
    let project = RegisteredProject(
      id: ProjectID(rawValue: "project-desktop-pipeline"),
      name: "Desktop Pipeline",
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: ProjectAccessPolicy(),
      verificationCommands: [command, command],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let scope = try TaskEvidenceScope(
      taskID: TaskID(rawValue: "task-desktop-pipeline"),
      projectID: project.id,
      threadID: ThreadID(rawValue: "thread-desktop-pipeline"),
      turnID: TurnID(rawValue: "turn-desktop-pipeline"),
      generation: 1,
      eventSequence: 8
    )

    let authorizationStore = try VerificationAuthorizationStore(
      path: directory.appendingPathComponent("authorization.json").path
    )
    let evidence = try await DesktopPipelineVerificationRunner(
      authorizations: DesktopVerificationAuthorizationBroker(store: authorizationStore)
    ).run(
      scope: scope,
      project: project,
      workingDirectory: root
    )

    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(evidence.first?.id, VerificationCommandIdentifier(command: command))
    XCTAssertEqual(evidence.first?.reportingEvidence.status, .unavailable)
    XCTAssertEqual(evidence.first?.reportingEvidence.required, true)
    XCTAssertEqual(
      evidence.first?.reportingEvidence.unavailableReason,
      "A one-time local verification authorization was not issued."
    )
  }

  func testOneTimeAuthorizationIsConsumedByProductionRunner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-desktop-pipeline-authorized-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let root = try RegisteredRoot(capturing: directory)
    let command = try VerificationCommand(executable: "/usr/bin/true", arguments: [])
    let project = RegisteredProject(
      id: ProjectID(rawValue: "project-desktop-authorized"),
      name: "Authorized Pipeline",
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: ProjectAccessPolicy(),
      verificationCommands: [command, command],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let taskID = TaskID(rawValue: "task-desktop-authorized")
    let binding = ExecutionBinding(
      threadID: ThreadID(rawValue: "thread-desktop-authorized"),
      turnID: TurnID(rawValue: "turn-desktop-authorized"),
      turnGeneration: 3
    )
    let scope = try TaskEvidenceScope(
      taskID: taskID,
      projectID: project.id,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: 3,
      eventSequence: 8
    )
    let store = try VerificationAuthorizationStore(
      path: directory.appendingPathComponent("authorization.json").path
    )
    let broker = DesktopVerificationAuthorizationBroker(store: store)
    try await broker.authorize(
      taskID: taskID,
      binding: binding,
      project: project,
      workingDirectory: root
    )

    let evidence = try await DesktopPipelineVerificationRunner(
      authorizations: broker
    ).run(scope: scope, project: project, workingDirectory: root)

    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(evidence.first?.reportingEvidence.status, .passed)
    XCTAssertEqual(evidence.first?.reportingEvidence.exitCode, 0)
    let second = try await DesktopPipelineVerificationRunner(authorizations: broker).run(
      scope: scope,
      project: project,
      workingDirectory: root
    )
    XCTAssertEqual(second.first?.reportingEvidence.status, .unavailable)
  }
}
