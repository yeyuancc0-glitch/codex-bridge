import BridgeCodexRPC
import BridgeDomain
import BridgeSecurity
import CryptoKit
import Foundation
import XCTest

@testable import BridgeRuntime

final class CodexApprovalEvidenceBuilderTests: XCTestCase {
  func testRejectsDisplayCommandMismatchAndItemMismatch() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = try RegisteredRoot(capturing: rootURL)
    let item = try CodexApprovalWireDecoder.decodeItemStarted(commandItem())

    XCTAssertThrowsError(
      try build(
        request: commandRequest(command: "different", itemID: "item-1"), item: item, root: root)
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
    XCTAssertThrowsError(
      try build(
        request: commandRequest(command: "tool run", itemID: "item-2"), item: item, root: root)
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
    XCTAssertThrowsError(
      try build(
        request: commandRequest(command: "tool run", itemID: "item-1", mismatchedAction: true),
        item: item,
        root: root
      )
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
  }

  func testBuildsCompleteNormalizedFileManifestBoundToRootIdentity() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = try RegisteredRoot(capturing: rootURL)
    let diffs = ["new", "", "hello 🌍"]
    let item = fileItem(changes: [
      fileChange(path: "Sources/New.swift", diff: diffs[0], kind: "add"),
      fileChange(
        path: root.canonicalPath + "/Sources/Old.swift", diff: diffs[1], kind: "delete"),
      fileChange(
        path: root.canonicalPath + "/Sources/./App.swift",
        movePath: "Sources/Generated/../Main.swift",
        diff: diffs[2]
      ),
    ])
    let evidence = try build(
      request: fileRequest(grantRoot: root.canonicalPath + "/."),
      item: try CodexApprovalWireDecoder.decodeItemStarted(item),
      itemNotification: item,
      root: root
    )

    let manifest = try XCTUnwrap(evidence.fileChangeManifest)
    XCTAssertEqual(manifest.rootDevice, root.identity.device)
    XCTAssertEqual(manifest.rootInode, root.identity.inode)
    XCTAssertEqual(manifest.totalDiffBytes, diffs.reduce(0) { $0 + $1.utf8.count })
    XCTAssertEqual(manifest.entries.count, 3)
    XCTAssertEqual(manifest.entries[0].path, "Sources/New.swift")
    XCTAssertEqual(manifest.entries[0].kind, .add)
    XCTAssertNil(manifest.entries[0].movePath)
    XCTAssertEqual(manifest.entries[1].path, "Sources/Old.swift")
    XCTAssertEqual(manifest.entries[1].kind, .delete)
    XCTAssertNil(manifest.entries[1].movePath)
    XCTAssertEqual(manifest.entries[2].path, "Sources/App.swift")
    XCTAssertEqual(manifest.entries[2].kind, .update)
    XCTAssertEqual(manifest.entries[2].movePath, "Sources/Main.swift")
    XCTAssertEqual(manifest.entries[2].diffByteCount, diffs[2].utf8.count)
    XCTAssertEqual(
      manifest.entries[2].diffSHA256,
      SHA256.hash(data: Data(diffs[2].utf8)).map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(
      evidence.changedPaths,
      ["Sources/New.swift", "Sources/Old.swift", "Sources/App.swift", "Sources/Main.swift"]
    )
    XCTAssertEqual(evidence.workingDirectory, ".")
  }

  func testFileManifestRejectsMismatchedGrantRootEscapesAndEntryOverflow() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = try RegisteredRoot(capturing: rootURL)
    let validItem = fileItem(path: "Sources/App.swift", movePath: nil, diff: "diff")

    XCTAssertThrowsError(
      try build(
        request: fileRequest(grantRoot: root.canonicalPath + "-other"),
        item: CodexApprovalWireDecoder.decodeItemStarted(validItem),
        itemNotification: validItem,
        root: root
      )
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }

    for escaped in ["../outside", root.canonicalPath + "-other/file.swift"] {
      let item = fileItem(path: escaped, movePath: nil, diff: "diff")
      XCTAssertThrowsError(
        try build(
          request: fileRequest(grantRoot: root.canonicalPath),
          item: CodexApprovalWireDecoder.decodeItemStarted(item),
          itemNotification: item,
          root: root
        )
      ) { error in
        XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
      }
    }
    let escapedMove = fileItem(
      path: "Sources/App.swift",
      movePath: "../outside.swift",
      diff: "diff"
    )
    XCTAssertThrowsError(
      try build(
        request: fileRequest(grantRoot: root.canonicalPath),
        item: CodexApprovalWireDecoder.decodeItemStarted(escapedMove),
        itemNotification: escapedMove,
        root: root
      )
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }

    let overflowItem = fileItem(
      changes: (0...CodexApprovalFileChangeManifest.maximumEntries).map { index in
        fileChange(path: "Sources/File\(index).swift", diff: "x")
      }
    )
    XCTAssertThrowsError(
      try build(
        request: fileRequest(grantRoot: root.canonicalPath),
        item: CodexApprovalWireDecoder.decodeItemStarted(overflowItem),
        itemNotification: overflowItem,
        root: root
      )
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
  }

  func testCommandAndPermissionsEvidenceNeverContainFileManifest() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = try RegisteredRoot(capturing: rootURL)
    let commandNotification = commandItem(cwd: root.canonicalPath)
    let command = try build(
      request: commandRequest(
        command: "tool run",
        itemID: "item-1",
        cwd: root.canonicalPath
      ),
      item: CodexApprovalWireDecoder.decodeItemStarted(commandNotification),
      itemNotification: commandNotification,
      root: root
    )
    XCTAssertNil(command.fileChangeManifest)

    let permissions = try build(
      request: permissionsRequest(cwd: root.canonicalPath),
      item: CodexApprovalWireDecoder.decodeItemStarted(commandNotification),
      itemNotification: commandNotification,
      root: root
    )
    XCTAssertNil(permissions.fileChangeManifest)
  }

  private func build(
    request: RPCServerRequest,
    item: CodexApprovalItemEvidence,
    itemNotification: RPCNotification? = nil,
    root: RegisteredRoot
  ) throws -> CodexApprovalEvidence {
    try CodexApprovalEvidenceBuilder.build(
      approvalID: ApprovalID(rawValue: "approval-1"),
      request: CodexApprovalWireDecoder.decode(request),
      requestParameters: request.params ?? .null,
      itemEvidence: item,
      itemSourceDigest: try CodexApprovalEvidenceBuilder.canonicalSource(
        itemNotification?.params ?? commandItem().params ?? .null
      ).digest,
      root: root
    )
  }

  private func commandRequest(
    command: String,
    itemID: String,
    mismatchedAction: Bool = false,
    cwd: String = "/workspace"
  ) -> RPCServerRequest {
    var parameters: [String: JSONValue] = [
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string(itemID),
      "startedAtMs": .integer(1),
      "command": .string(command),
      "cwd": .string(cwd),
    ]
    if mismatchedAction {
      parameters["commandActions"] = .array([
        .object([
          "type": .string("unknown"),
          "command": .string("different display action"),
        ])
      ])
    }
    return RPCServerRequest(
      id: .string("request-1"),
      method: "item/commandExecution/requestApproval",
      params: .object(parameters)
    )
  }

  private func commandItem(cwd: String = "/workspace") -> RPCNotification {
    RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(1),
        "item": .object([
          "id": .string("item-1"),
          "type": .string("commandExecution"),
          "command": .string("tool run"),
          "commandActions": .array([]),
          "cwd": .string(cwd),
          "status": .string("inProgress"),
        ]),
      ])
    )
  }

  private func fileRequest(grantRoot: String) -> RPCServerRequest {
    RPCServerRequest(
      id: .string("request-file"),
      method: "item/fileChange/requestApproval",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "itemId": .string("item-file"),
        "startedAtMs": .integer(2),
        "grantRoot": .string(grantRoot),
      ])
    )
  }

  private func permissionsRequest(cwd: String) -> RPCServerRequest {
    RPCServerRequest(
      id: .string("request-permissions"),
      method: "item/permissions/requestApproval",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "itemId": .string("item-1"),
        "startedAtMs": .integer(1),
        "cwd": .string(cwd),
        "permissions": .object([:]),
      ])
    )
  }

  private func fileItem(
    path: String,
    movePath: String?,
    diff: String
  ) -> RPCNotification {
    fileItem(changes: [fileChange(path: path, movePath: movePath, diff: diff)])
  }

  private func fileItem(changes: [JSONValue]) -> RPCNotification {
    RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(2),
        "item": .object([
          "id": .string("item-file"),
          "type": .string("fileChange"),
          "changes": .array(changes),
          "status": .string("inProgress"),
        ]),
      ])
    )
  }

  private func fileChange(
    path: String,
    movePath: String? = nil,
    diff: String,
    kind kindType: String = "update"
  ) -> JSONValue {
    var kind: [String: JSONValue] = ["type": .string(kindType)]
    if let movePath { kind["move_path"] = .string(movePath) }
    return .object([
      "path": .string(path),
      "diff": .string(diff),
      "kind": .object(kind),
    ])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-approval-evidence-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
