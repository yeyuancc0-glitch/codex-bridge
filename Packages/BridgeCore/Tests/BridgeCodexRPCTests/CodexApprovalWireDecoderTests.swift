import XCTest

@testable import BridgeCodexRPC

final class CodexApprovalWireDecoderTests: XCTestCase {
  func testDecodesMinimalAndCompleteCommandRequests() throws {
    let minimal = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: commonParams())
    )
    guard case .command(let minimalCommand) = minimal else {
      return XCTFail("Expected command request")
    }
    XCTAssertNil(minimalCommand.correlation.callbackID)
    XCTAssertNil(minimalCommand.displayCommand)
    XCTAssertNil(minimalCommand.displayActions)

    var params = commonParams()
    params["approvalId"] = .string("callback-1")
    params["command"] = .string("/usr/bin/git status --short")
    params["cwd"] = .string("/workspace/project")
    params["reason"] = .string("Inspect the worktree.")
    params["environmentId"] = .string("local")
    params["commandActions"] = .array([
      .object([
        "type": .string("read"),
        "command": .string("cat README.md"),
        "name": .string("README.md"),
        "path": .string("/workspace/project/README.md"),
      ]),
      .object([
        "type": .string("search"),
        "command": .string("rg bridge Sources"),
        "path": .string("Sources"),
        "query": .string("bridge"),
      ]),
    ])
    params["networkApprovalContext"] = .object([
      "host": .string("example.com"),
      "protocol": .string("https"),
    ])
    params["proposedExecpolicyAmendment"] = .array([.string("prefix_rule")])
    params["proposedNetworkPolicyAmendments"] = .array([
      .object(["action": .string("allow"), "host": .string("example.com")])
    ])

    let complete = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: params)
    )
    guard case .command(let command) = complete else { return XCTFail("Expected command") }
    XCTAssertEqual(command.correlation.callbackID, "callback-1")
    XCTAssertEqual(command.displayCommand, "/usr/bin/git status --short")
    XCTAssertEqual(command.displayActions?.count, 2)
    XCTAssertEqual(command.networkContext?.protocol, .https)
    XCTAssertEqual(command.proposedNetworkPolicyAmendments?.first?.action, .allow)
  }

  func testDecodesMinimalAndCompleteFileChangeRequests() throws {
    let minimal = try CodexApprovalWireDecoder.decode(
      request(method: "item/fileChange/requestApproval", params: commonParams())
    )
    guard case .fileChange(let minimalFile) = minimal else {
      return XCTFail("Expected file request")
    }
    XCTAssertNil(minimalFile.grantRoot)
    XCTAssertNil(minimalFile.reason)

    var params = commonParams()
    params["grantRoot"] = .string("/workspace/project")
    params["reason"] = .string("Write the approved file.")
    let complete = try CodexApprovalWireDecoder.decode(
      request(method: "item/fileChange/requestApproval", params: params)
    )
    guard case .fileChange(let file) = complete else { return XCTFail("Expected file") }
    XCTAssertEqual(file.grantRoot, "/workspace/project")
    XCTAssertEqual(file.reason, "Write the approved file.")
  }

  func testDecodesMinimalAndCompletePermissionProfiles() throws {
    var minimalParams = commonParams()
    minimalParams["cwd"] = .string("/workspace/project")
    minimalParams["permissions"] = .object([:])
    let minimal = try CodexApprovalWireDecoder.decode(
      request(method: "item/permissions/requestApproval", params: minimalParams)
    )
    guard case .permissions(let minimalPermissions) = minimal else {
      return XCTFail("Expected permissions request")
    }
    XCTAssertNil(minimalPermissions.permissions.fileSystem)
    XCTAssertNil(minimalPermissions.permissions.network)

    var params = minimalParams
    params["environmentId"] = .string("local")
    params["reason"] = .string("Read fixtures and write build output.")
    params["permissions"] = .object([
      "fileSystem": .object([
        "globScanMaxDepth": .integer(4),
        "read": .array([.string("/workspace/project/Fixtures")]),
        "write": .array([.string("/workspace/project/.build")]),
        "entries": .array([
          permissionEntry(
            access: "read",
            path: [
              "type": .string("path"), "path": .string("/workspace/project/README.md"),
            ]),
          permissionEntry(
            access: "write",
            path: [
              "type": .string("glob_pattern"), "pattern": .string(".build/**"),
            ]),
          permissionEntry(
            access: "deny",
            path: [
              "type": .string("special"),
              "value": .object([
                "kind": .string("project_roots"), "subpath": .string("Secrets"),
              ]),
            ]),
        ]),
      ]),
      "network": .object(["enabled": .bool(false)]),
    ])

    let complete = try CodexApprovalWireDecoder.decode(
      request(method: "item/permissions/requestApproval", params: params)
    )
    guard case .permissions(let permissions) = complete else {
      return XCTFail("Expected permissions")
    }
    XCTAssertEqual(permissions.workingDirectory, "/workspace/project")
    XCTAssertEqual(permissions.permissions.fileSystem?.entries?.count, 3)
    XCTAssertEqual(permissions.permissions.fileSystem?.globScanMaximumDepth, 4)
    XCTAssertEqual(permissions.permissions.network?.enabled, false)
  }

  func testDecodesCommandAndFileItemEvidence() throws {
    let command = RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(8),
        "item": .object([
          "id": .string("item-command"),
          "type": .string("commandExecution"),
          "command": .string("/usr/bin/git status"),
          "commandActions": .array([]),
          "cwd": .string("/workspace/project"),
          "status": .string("inProgress"),
        ]),
      ])
    )
    guard
      case .commandExecution(let commandEvidence) =
        try CodexApprovalWireDecoder.decodeItemStarted(command)
    else { return XCTFail("Expected command evidence") }
    XCTAssertEqual(commandEvidence.item.itemID, "item-command")
    XCTAssertEqual(commandEvidence.displayCommand, "/usr/bin/git status")

    let file = RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(9),
        "item": .object([
          "id": .string("item-file"),
          "type": .string("fileChange"),
          "status": .string("inProgress"),
          "changes": .array([
            .object([
              "path": .string("Sources/App.swift"),
              "diff": .string("+let ready = true"),
              "kind": .object([
                "type": .string("update"), "move_path": .string("Sources/Main.swift"),
              ]),
            ])
          ]),
        ]),
      ])
    )
    guard
      case .fileChange(let fileEvidence) = try CodexApprovalWireDecoder.decodeItemStarted(file)
    else { return XCTFail("Expected file evidence") }
    XCTAssertEqual(fileEvidence.changes.first?.path, "Sources/App.swift")
    XCTAssertEqual(
      fileEvidence.changes.first?.kind,
      .update(movePath: "Sources/Main.swift")
    )
  }

  func testDecodesBoundedPlanUpdateSemanticEvidence() throws {
    let notification = RPCNotification(
      method: "turn/plan/updated",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "explanation": .string("The implementation plan changed."),
        "plan": .array([
          .object(["step": .string("Inspect"), "status": .string("completed")]),
          .object(["step": .string("Implement"), "status": .string("inProgress")]),
        ]),
      ])
    )

    guard
      case .planChanged(let evidence) =
        try CodexApprovalWireDecoder.decodeSemanticNotification(notification)
    else { return XCTFail("Expected plan evidence") }
    XCTAssertEqual(evidence.threadID, "thread-1")
    XCTAssertEqual(evidence.steps.map(\.status), [.completed, .inProgress])
  }

  func testDecodesCompletedCommandAndFileSemanticEvidence() throws {
    let command = RPCNotification(
      method: "item/completed",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "completedAtMs": .integer(8),
        "item": .object([
          "id": .string("command-1"),
          "type": .string("commandExecution"),
          "command": .string("swift test"),
          "status": .string("failed"),
          "exitCode": .integer(1),
        ]),
      ])
    )
    guard
      case .commandCompleted(let commandEvidence) =
        try CodexApprovalWireDecoder.decodeSemanticNotification(command)
    else { return XCTFail("Expected command completion") }
    XCTAssertEqual(commandEvidence.exitCode, 1)
    XCTAssertEqual(commandEvidence.status, .failed)

    let file = RPCNotification(
      method: "item/completed",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "completedAtMs": .integer(9),
        "item": .object([
          "id": .string("file-1"),
          "type": .string("fileChange"),
          "status": .string("completed"),
          "changes": .array([
            fileUpdate(
              path: "Sources/App.swift",
              diff: "+let ready = true",
              kind: .object(["type": .string("add")])
            )
          ]),
        ]),
      ])
    )
    guard
      case .fileChangeCompleted(let fileEvidence) =
        try CodexApprovalWireDecoder.decodeSemanticNotification(file)
    else { return XCTFail("Expected file completion") }
    XCTAssertEqual(fileEvidence.changes.count, 1)
    XCTAssertEqual(fileEvidence.status, .completed)
  }

  func testSemanticDecoderRejectsInProgressCompletionAndUnknownPlanStatus() {
    let command = RPCNotification(
      method: "item/completed",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "completedAtMs": .integer(8),
        "item": .object([
          "id": .string("command-1"),
          "type": .string("commandExecution"),
          "command": .string("swift test"),
          "status": .string("inProgress"),
          "exitCode": .null,
        ]),
      ])
    )
    XCTAssertThrowsError(try CodexApprovalWireDecoder.decodeSemanticNotification(command))

    let plan = RPCNotification(
      method: "turn/plan/updated",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "plan": .array([
          .object(["step": .string("Inspect"), "status": .string("future")])
        ]),
      ])
    )
    XCTAssertThrowsError(try CodexApprovalWireDecoder.decodeSemanticNotification(plan))
  }

  func testDecodesEveryCommandActionAndFileChangeKind() throws {
    var params = commonParams()
    params["commandActions"] = .array([
      .object([
        "type": .string("read"), "command": .string("cat a"),
        "name": .string("a"), "path": .string("a"),
      ]),
      .object([
        "type": .string("listFiles"), "command": .string("ls"), "path": .null,
      ]),
      .object([
        "type": .string("search"), "command": .string("rg q"),
        "path": .string("Sources"), "query": .string("q"),
      ]),
      .object(["type": .string("unknown"), "command": .string("custom")]),
    ])
    guard
      case .command(let command) = try CodexApprovalWireDecoder.decode(
        request(method: "item/commandExecution/requestApproval", params: params))
    else { return XCTFail("Expected command") }
    XCTAssertEqual(command.displayActions?.count, 4)

    let notification = fileNotification(
      changes: [
        fileUpdate(path: "added", kind: .object(["type": .string("add")])),
        fileUpdate(path: "deleted", kind: .object(["type": .string("delete")])),
        fileUpdate(
          path: "updated",
          kind: .object(["type": .string("update"), "move_path": .null])),
      ]
    )
    guard
      case .fileChange(let evidence) = try CodexApprovalWireDecoder.decodeItemStarted(notification)
    else { return XCTFail("Expected file evidence") }
    XCTAssertEqual(evidence.changes.map(\.kind), [.add, .delete, .update(movePath: nil)])
  }

  func testDecodesEveryPermissionPathUnion() throws {
    let paths: [[String: JSONValue]] = [
      ["type": .string("path"), "path": .string("/workspace/file")],
      ["type": .string("glob_pattern"), "pattern": .string("Sources/**")],
      specialPath(["kind": .string("root")]),
      specialPath(["kind": .string("minimal")]),
      specialPath(["kind": .string("project_roots"), "subpath": .null]),
      specialPath(["kind": .string("tmpdir")]),
      specialPath(["kind": .string("slash_tmp")]),
      specialPath([
        "kind": .string("unknown"), "path": .string("/custom"),
        "subpath": .string("child"),
      ]),
    ]
    var params = permissionParams()
    params["permissions"] = .object([
      "fileSystem": .object([
        "entries": .array(paths.map { permissionEntry(access: "read", path: $0) })
      ])
    ])
    guard
      case .permissions(let request) = try CodexApprovalWireDecoder.decode(
        request(method: "item/permissions/requestApproval", params: params))
    else { return XCTFail("Expected permissions") }
    XCTAssertEqual(request.permissions.fileSystem?.entries?.count, paths.count)
  }

  func testRejectsMissingWrongTypeAndNegativeTimestamp() {
    var missing = commonParams()
    missing["itemId"] = nil
    assertError(
      request(method: "item/fileChange/requestApproval", params: missing),
      equals: .missingField("itemId")
    )

    var wrongType = commonParams()
    wrongType["turnId"] = .integer(3)
    assertError(
      request(method: "item/fileChange/requestApproval", params: wrongType),
      equals: .invalidField("turnId")
    )

    var negative = commonParams()
    negative["startedAtMs"] = .integer(-1)
    assertError(
      request(method: "item/fileChange/requestApproval", params: negative),
      equals: .invalidField("startedAtMs")
    )
  }

  func testPermissionUnionsAndNestedObjectsAreClosed() {
    var params = permissionParams()
    params["permissions"] = .object(["future": .bool(true)])
    assertError(
      request(method: "item/permissions/requestApproval", params: params),
      equals: .unknownField(context: "permissions", field: "future")
    )

    params = permissionParams()
    params["permissions"] = .object([
      "fileSystem": .object([
        "entries": .array([
          permissionEntry(
            access: "execute",
            path: [
              "type": .string("path"), "path": .string("/workspace/tool"),
            ])
        ])
      ])
    ])
    assertError(
      request(method: "item/permissions/requestApproval", params: params),
      equals: .unknownDiscriminator(
        field: "permissions.fileSystem.entries[0].access", value: "execute")
    )

    params = permissionParams()
    params["permissions"] = .object([
      "fileSystem": .object([
        "entries": .array([
          permissionEntry(access: "read", path: ["type": .string("future")])
        ])
      ])
    ])
    assertError(
      request(method: "item/permissions/requestApproval", params: params),
      equals: .unknownDiscriminator(
        field: "permissions.fileSystem.entries[0].path.type", value: "future")
    )

    params = permissionParams()
    params["permissions"] = .object([
      "network": .object(["enabled": .bool(false), "future": .bool(true)])
    ])
    assertError(
      request(method: "item/permissions/requestApproval", params: params),
      equals: .unknownField(context: "permissions.network", field: "future")
    )
  }

  func testRejectsUnknownCommandActionAndNonNormalizedPermissionCWD() {
    var command = commonParams()
    command["commandActions"] = .array([
      .object(["type": .string("execute"), "command": .string("tool")])
    ])
    assertError(
      request(method: "item/commandExecution/requestApproval", params: command),
      equals: .unknownDiscriminator(field: "commandActions[0].type", value: "execute")
    )

    var permissions = permissionParams()
    permissions["cwd"] = .string("/workspace/../private")
    assertError(
      request(method: "item/permissions/requestApproval", params: permissions),
      equals: .invalidField("cwd")
    )
  }

  func testIdentifierGeneralStringAndCommandBoundaries() throws {
    var params = commonParams()
    params["threadId"] = .string(String(repeating: "i", count: 256))
    _ = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: params))
    params["threadId"] = .string(String(repeating: "i", count: 257))
    assertError(
      request(method: "item/commandExecution/requestApproval", params: params),
      equals: .stringTooLarge(field: "threadId", maximumBytes: 256)
    )

    _ = try CodexApprovalWireDecoder.decode(
      RPCServerRequest(
        id: .string(String(repeating: "r", count: 256)),
        method: "item/fileChange/requestApproval",
        params: .object(commonParams())
      ))
    let oversizedRequestID = RPCServerRequest(
      id: .string(String(repeating: "r", count: 257)),
      method: "item/fileChange/requestApproval",
      params: .object(commonParams())
    )
    assertError(
      oversizedRequestID,
      equals: .stringTooLarge(field: "requestId", maximumBytes: 256)
    )

    params = commonParams()
    params["reason"] = .string(String(repeating: "r", count: 4 * 1024))
    _ = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: params))
    params["reason"] = .string(String(repeating: "r", count: 4 * 1024 + 1))
    assertError(
      request(method: "item/commandExecution/requestApproval", params: params),
      equals: .stringTooLarge(field: "reason", maximumBytes: 4 * 1024)
    )

    params = commonParams()
    params["command"] = .string(String(repeating: "c", count: 64 * 1024))
    _ = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: params))
    params["command"] = .string(String(repeating: "c", count: 64 * 1024 + 1))
    assertError(
      request(method: "item/commandExecution/requestApproval", params: params),
      equals: .stringTooLarge(field: "command", maximumBytes: 64 * 1024)
    )
  }

  func testArrayDiffAndTotalEvidenceBoundaries() throws {
    var params = commonParams()
    params["commandActions"] = .array(
      Array(
        repeating: .object(["type": .string("unknown"), "command": .string("true")]),
        count: 256
      ))
    _ = try CodexApprovalWireDecoder.decode(
      request(method: "item/commandExecution/requestApproval", params: params))
    params["commandActions"] = .array(
      Array(
        repeating: .object(["type": .string("unknown"), "command": .string("true")]),
        count: 257
      ))
    assertError(
      request(method: "item/commandExecution/requestApproval", params: params),
      equals: .arrayTooLarge(field: "commandActions", maximumCount: 256)
    )

    let acceptedDiff = String(repeating: "d", count: 256 * 1024)
    _ = try CodexApprovalWireDecoder.decodeItemStarted(fileNotification(diff: acceptedDiff))
    XCTAssertThrowsError(
      try CodexApprovalWireDecoder.decodeItemStarted(
        fileNotification(diff: acceptedDiff + "d"))
    ) { error in
      XCTAssertEqual(
        error as? CodexApprovalWireError,
        .stringTooLarge(field: "diff", maximumBytes: 256 * 1024)
      )
    }

    let exact = try requestWithEncodedParamsSize(CodexApprovalWireLimits.totalEvidenceBytes)
    _ = try CodexApprovalWireDecoder.decode(exact)
    let oversized = try requestWithEncodedParamsSize(
      CodexApprovalWireLimits.totalEvidenceBytes + 1)
    XCTAssertThrowsError(try CodexApprovalWireDecoder.decode(oversized)) { error in
      XCTAssertEqual(
        error as? CodexApprovalWireError,
        .evidenceTooLarge(maximumBytes: 512 * 1024)
      )
    }
  }

  func testLosslessEnvelopeMetadataRemainsIndependentOfTypedDecode() throws {
    let envelope = JSONValue.object([
      "id": .string("request-1"),
      "method": .string("item/fileChange/requestApproval"),
      "params": .object(commonParams()),
      "futureMetadata": .object(["kept": .bool(true)]),
    ])
    guard case .serverRequest(let request) = try RPCEnvelope.decode(envelope) else {
      return XCTFail("Expected server request")
    }
    _ = try CodexApprovalWireDecoder.decode(request)
    XCTAssertEqual(request.metadata["futureMetadata"], .object(["kept": .bool(true)]))
  }

  private func commonParams() -> [String: JSONValue] {
    [
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string("item-1"),
      "startedAtMs": .integer(1),
    ]
  }

  private func permissionParams() -> [String: JSONValue] {
    var params = commonParams()
    params["cwd"] = .string("/workspace/project")
    params["permissions"] = .object([:])
    return params
  }

  private func permissionEntry(
    access: String,
    path: [String: JSONValue]
  ) -> JSONValue {
    .object(["access": .string(access), "path": .object(path)])
  }

  private func specialPath(_ value: [String: JSONValue]) -> [String: JSONValue] {
    ["type": .string("special"), "value": .object(value)]
  }

  private func request(
    method: String,
    params: [String: JSONValue]
  ) -> RPCServerRequest {
    RPCServerRequest(id: .string("request-1"), method: method, params: .object(params))
  }

  private func assertError(
    _ request: RPCServerRequest,
    equals expected: CodexApprovalWireError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try CodexApprovalWireDecoder.decode(request), file: file, line: line) {
      error in
      XCTAssertEqual(error as? CodexApprovalWireError, expected, file: file, line: line)
    }
  }

  private func fileNotification(diff: String) -> RPCNotification {
    fileNotification(
      changes: [
        fileUpdate(
          path: "Sources/App.swift",
          diff: diff,
          kind: .object(["type": .string("update"), "move_path": .null]))
      ])
  }

  private func fileNotification(changes: [JSONValue]) -> RPCNotification {
    RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(1),
        "item": .object([
          "id": .string("item-1"),
          "type": .string("fileChange"),
          "status": .string("inProgress"),
          "changes": .array(changes),
        ]),
      ])
    )
  }

  private func fileUpdate(
    path: String,
    diff: String = "diff",
    kind: JSONValue
  ) -> JSONValue {
    .object(["path": .string(path), "diff": .string(diff), "kind": kind])
  }

  private func requestWithEncodedParamsSize(_ target: Int) throws -> RPCServerRequest {
    var params = commonParams()
    params["padding"] = .string("")
    let baseSize = try JSONEncoder().encode(JSONValue.object(params)).count
    XCTAssertLessThanOrEqual(baseSize, target)
    params["padding"] = .string(String(repeating: "p", count: target - baseSize))
    XCTAssertEqual(try JSONEncoder().encode(JSONValue.object(params)).count, target)
    return request(method: "item/fileChange/requestApproval", params: params)
  }
}
