import BridgeCodexRPC
import BridgeProjects
import BridgeServiceCore
import XCTest

@testable import BridgeCodexService

final class ExecutionApprovalBuilderTests: XCTestCase {
  func testCommandApprovalExposesNativeSessionAndRuleDecisions() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-command-approval-options"
    )
    let values = try commandValues(
      root: fixture.root.path,
      amendment: ["prefix_rule", "git", "status"]
    )

    let prepared = try build(
      values,
      task: task,
      project: fixture.project,
      root: fixture.root.path
    )

    XCTAssertEqual(
      prepared.request.availableDecisions,
      [.allow, .allowForSession, .allowSimilarCommands, .deny]
    )
    XCTAssertEqual(
      try prepared.response.value(for: .allowForSession),
      .object(["decision": .string("acceptForSession")])
    )
    XCTAssertEqual(
      try prepared.response.value(for: .allowSimilarCommands),
      .object([
        "decision": .object([
          "acceptWithExecpolicyAmendment": .object([
            "execpolicy_amendment": .array([
              .string("prefix_rule"), .string("git"), .string("status"),
            ])
          ])
        ])
      ])
    )
  }

  func testCommandApprovalDoesNotInventRuleDecisionWithoutProposal() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-command-approval-without-rule"
    )
    let values = try commandValues(root: fixture.root.path, amendment: nil)

    let prepared = try build(
      values,
      task: task,
      project: fixture.project,
      root: fixture.root.path
    )

    XCTAssertEqual(
      prepared.request.availableDecisions,
      [.allow, .allowForSession, .deny]
    )
    XCTAssertThrowsError(try prepared.response.value(for: .allowSimilarCommands))
  }

  func testNetworkPermissionCannotExceedTaskPolicy() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-permission-network-denied",
      networkAllowed: false
    )
    let values = try permissionValues(
      root: fixture.root.path,
      permissions: .object(["network": .object(["enabled": .bool(true)])])
    )

    XCTAssertThrowsError(
      try build(values, task: task, project: fixture.project, root: fixture.root.path)
    ) { error in
      XCTAssertEqual(error as? ExecutionServiceError, .approvalExceedsPolicy)
    }
  }

  func testWritePermissionCannotExceedProjectPolicy() async throws {
    let fixture = try await makeExecutionFixture(
      self,
      accessPolicy: ProjectAccessPolicy(read: .allowed, write: .denied, network: .allowed)
    )
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-permission-write-denied"
    )
    let values = try permissionValues(
      root: fixture.root.path,
      permissions: .object([
        "fileSystem": .object([
          "entries": .array([
            .object([
              "access": .string("write"),
              "path": .object([
                "type": .string("path"),
                "path": .string(fixture.root.appending(path: "Sources/A.swift").path),
              ]),
            ])
          ])
        ])
      ])
    )

    XCTAssertThrowsError(
      try build(values, task: task, project: fixture.project, root: fixture.root.path)
    ) { error in
      XCTAssertEqual(error as? ExecutionServiceError, .approvalExceedsPolicy)
    }
  }

  func testAllowedPermissionExposesRequestedScope() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-permission-visible",
      networkAllowed: true
    )
    let values = try permissionValues(
      root: fixture.root.path,
      permissions: .object([
        "fileSystem": .object([
          "entries": .array([
            .object([
              "access": .string("write"),
              "path": .object([
                "type": .string("path"),
                "path": .string(fixture.root.appending(path: "Sources/A.swift").path),
              ]),
            ])
          ])
        ]),
        "network": .object(["enabled": .bool(true)]),
      ])
    )

    let prepared = try build(
      values,
      task: task,
      project: fixture.project,
      root: fixture.root.path
    )

    XCTAssertEqual(prepared.request.relativePaths, ["Sources/A.swift"])
    XCTAssertTrue(prepared.request.displayCommand?.contains("File-system write") == true)
    XCTAssertTrue(prepared.request.displayCommand?.contains("Network access") == true)
  }

  private typealias PermissionValues = (CodexApprovalRequest, CodexApprovalItemEvidence, JSONValue)

  private func commandValues(
    root: String,
    amendment: [String]?
  ) throws -> PermissionValues {
    var values: [String: JSONValue] = [
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string("item-1"),
      "startedAtMs": .integer(1),
      "command": .string("git status"),
      "cwd": .string(root),
    ]
    if let amendment {
      values["proposedExecpolicyAmendment"] = .array(amendment.map(JSONValue.string))
    }
    let params = JSONValue.object(values)
    let request = try CodexApprovalWireDecoder.decode(
      RPCServerRequest(
        id: .string("request-command"),
        method: "item/commandExecution/requestApproval",
        params: params
      )
    )
    let evidence = try CodexApprovalWireDecoder.decodeItemStarted(
      RPCNotification(
        method: "item/started",
        params: .object([
          "threadId": .string("thread-1"),
          "turnId": .string("turn-1"),
          "startedAtMs": .integer(1),
          "item": .object([
            "id": .string("item-1"),
            "type": .string("commandExecution"),
            "command": .string("git status"),
            "commandActions": .array([]),
            "cwd": .string(root),
            "status": .string("inProgress"),
          ]),
        ])
      )
    )
    return (request, evidence, params)
  }

  private func permissionValues(root: String, permissions: JSONValue) throws -> PermissionValues {
    let params: JSONValue = .object([
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string("item-1"),
      "startedAtMs": .integer(1),
      "cwd": .string(root),
      "permissions": permissions,
    ])
    let request = try CodexApprovalWireDecoder.decode(
      RPCServerRequest(
        id: .string("request-permissions"),
        method: "item/permissions/requestApproval",
        params: params
      )
    )
    let evidence = try CodexApprovalWireDecoder.decodeItemStarted(
      RPCNotification(
        method: "item/started",
        params: .object([
          "threadId": .string("thread-1"),
          "turnId": .string("turn-1"),
          "startedAtMs": .integer(1),
          "item": .object([
            "id": .string("item-1"),
            "type": .string("commandExecution"),
            "command": .string("tool"),
            "commandActions": .array([]),
            "cwd": .string(root),
            "status": .string("inProgress"),
          ]),
        ])
      )
    )
    return (request, evidence, params)
  }

  private func build(
    _ values: PermissionValues,
    task: ServiceTaskRecord,
    project: ServiceProjectRecord,
    root: String
  ) throws -> PreparedExecutionApproval {
    let request = try ExecutionRequest(task: task, project: project)
    return try ExecutionApprovalBuilder.build(
      approvalID: "apr-test",
      taskID: task.id,
      binding: try ExecutionBinding(threadID: "thread-1", turnID: "turn-1"),
      request: values.0,
      itemEvidence: values.1,
      rawParameters: values.2,
      projectRoot: root,
      limits: ExecutionApprovalLimits(request: request)
    )
  }
}
