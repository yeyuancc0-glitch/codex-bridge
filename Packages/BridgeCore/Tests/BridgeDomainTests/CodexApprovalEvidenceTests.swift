import Foundation
import XCTest

@testable import BridgeDomain

final class CodexApprovalEvidenceTests: XCTestCase {
  func testEvidenceRoundTripsAndRejectsCorruptedPersistedFields() throws {
    let evidence = try makeEvidence()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(evidence)

    XCTAssertEqual(try JSONDecoder().decode(CodexApprovalEvidence.self, from: data), evidence)

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["startedAtMilliseconds"] = -1
    let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(try JSONDecoder().decode(CodexApprovalEvidence.self, from: corrupted)) {
      error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidTimestamp)
    }
  }

  func testEvidenceEnforcesSnapshotSafeTextAndCollectionBounds() throws {
    XCTAssertThrowsError(
      try makeEvidence(displayArguments: Array(repeating: "action", count: 9))
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
    XCTAssertThrowsError(
      try makeEvidence(displayCommand: String(repeating: "x", count: 8 * 1_024 + 1))
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidText)
    }
    XCTAssertThrowsError(try makeEvidence(digest: String(repeating: "g", count: 64))) {
      error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidDigest)
    }
    XCTAssertThrowsError(try makeEvidence(digest: String(repeating: "١", count: 32))) {
      error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidDigest)
    }
  }

  private func makeEvidence(
    displayCommand: String? = "/usr/bin/git status",
    displayArguments: [String] = ["Read repository status"],
    digest: String = String(repeating: "a", count: 64)
  ) throws -> CodexApprovalEvidence {
    try CodexApprovalEvidence(
      approvalID: ApprovalID(rawValue: "apr-evidence"),
      kind: .command,
      authority: .correlatedDisplayOnly,
      threadID: ThreadID(rawValue: "thread-evidence"),
      turnID: TurnID(rawValue: "turn-evidence"),
      itemID: "item-evidence",
      callbackID: "callback-evidence",
      startedAtMilliseconds: 42,
      operationTitle: "Command approval",
      displayCommand: displayCommand,
      displayArguments: displayArguments,
      workingDirectory: "/private/project",
      reason: "Codex requested permission to continue.",
      evidenceDigest: digest
    )
  }
}
