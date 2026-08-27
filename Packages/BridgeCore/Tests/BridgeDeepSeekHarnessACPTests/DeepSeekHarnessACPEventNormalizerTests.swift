import BridgeACP
import BridgeAgentCore
import BridgeDomain
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPEventNormalizerTests: XCTestCase {
  func testFinalContentIsAuthoritativeAfterOrderedDeltas() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding
    )
    let first = try await normalizer.normalize(
      .init(sequence: 0, event: .textDelta(sessionID: "session", text: "A"))
    )
    let second = try await normalizer.normalize(
      .init(sequence: 1, event: .textDelta(sessionID: "session", text: "B"))
    )
    let final = try await normalizer.finalizeContent()
    XCTAssertEqual(first?.providerSequence, 0)
    XCTAssertEqual(second?.providerSequence, 1)
    XCTAssertEqual(final.first?.providerSequence, 2)
    guard case .content(let update) = final.first?.event else {
      return XCTFail("Expected authoritative content")
    }
    XCTAssertEqual(update.mode, .full)
    XCTAssertEqual(update.content, "AB")
    XCTAssertTrue(update.isFinal)
    XCTAssertTrue(update.authoritative)
  }

  func testMismatchedSessionIsRejected() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding
    )
    do {
      _ = try await normalizer.normalize(
        .init(sequence: 0, event: .textDelta(sessionID: "other", text: "bad"))
      )
      XCTFail("Expected a session mismatch")
    } catch let error as DeepSeekHarnessACPError {
      XCTAssertEqual(error, .sessionMismatch)
    }
  }

  func testPermissionRequestUsesSharedApprovalContract() async throws {
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: AgentInstallationID(rawValue: "installation"),
      providerSessionID: "session",
      providerRunID: "run"
    )
    let normalizer = DeepSeekHarnessACPEventNormalizer(
      taskID: TaskID(rawValue: "task"),
      binding: binding,
      projectRoot: "/tmp/project"
    )
    let request = DeepSeekHarnessACPPermissionRequest(
      approvalID: "deepseek-approval",
      requestID: .string("rpc-1"),
      sessionID: "session",
      toolCallID: "tool-1",
      title: "Run command",
      kind: "execute",
      rawInput: .object([
        "command": .string("swift test"),
        "path": .string("/tmp/project/Package.swift"),
      ]),
      options: [
        try AgentApprovalOption(id: "allow-once", name: "Allow", kind: "allow_once"),
        try AgentApprovalOption(id: "reject-once", name: "Reject", kind: "reject_once"),
      ]
    )

    let envelope = try await normalizer.normalize(
      .init(sequence: 0, event: .permissionRequested(request))
    )
    guard case .approvalRequested(let approval) = envelope?.event else {
      return XCTFail("Expected a standard approval request")
    }
    XCTAssertEqual(approval.approvalID, "deepseek-approval")
    XCTAssertEqual(approval.providerItemID, "tool-1")
    XCTAssertEqual(approval.kind, .command)
    XCTAssertEqual(approval.normalizedCommand, "swift test")
    XCTAssertEqual(approval.relativePaths, ["Package.swift"])
    XCTAssertEqual(approval.options.map(\.kind), ["allow_once", "reject_once"])
  }
}
