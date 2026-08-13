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

  func testFullFileManifestRoundTripsAndLegacyEvidenceDefaultsToNil() throws {
    let entry = try manifestEntry(path: "Sources/App.swift", byteCount: 12)
    let manifest = try CodexApprovalFileChangeManifest(
      entries: [entry],
      totalDiffBytes: 12,
      rootDevice: 42,
      rootInode: 84
    )
    let evidence = try makeEvidence(
      kind: .fileChange,
      authority: .correlatedFileChanges,
      fileChangeManifest: manifest
    )
    let data = try JSONEncoder().encode(evidence)

    let decoded = try JSONDecoder().decode(CodexApprovalEvidence.self, from: data)
    XCTAssertEqual(decoded.fileChangeManifest, manifest)

    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "fileChangeManifest")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    XCTAssertNil(
      try JSONDecoder().decode(CodexApprovalEvidence.self, from: legacyData).fileChangeManifest)
  }

  func testFileManifestRejectsInvalidPathsKindsAndBounds() throws {
    XCTAssertThrowsError(try manifestEntry(path: "../outside", byteCount: 1)) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidText)
    }
    XCTAssertThrowsError(
      try CodexApprovalFileChangeManifestEntry(
        path: "Sources/App.swift",
        kind: .add,
        movePath: "Sources/Main.swift",
        diffByteCount: 1,
        diffSHA256: String(repeating: "a", count: 64)
      )
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
    XCTAssertThrowsError(
      try manifestEntry(
        path: "Sources/App.swift",
        byteCount: CodexApprovalFileChangeManifest.maximumTotalDiffBytes + 1
      )
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
    let entry = try manifestEntry(path: "Sources/App.swift", byteCount: 1)
    XCTAssertThrowsError(
      try CodexApprovalFileChangeManifest(
        entries: Array(repeating: entry, count: 101),
        totalDiffBytes: 101,
        rootDevice: 1,
        rootInode: 2
      )
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
    XCTAssertThrowsError(
      try CodexApprovalFileChangeManifest(
        entries: [entry],
        totalDiffBytes: 2,
        rootDevice: 1,
        rootInode: 2
      )
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
    let largeEntries = try (0..<CodexApprovalFileChangeManifest.maximumEntries).map { index in
      try manifestEntry(
        path: "Sources/\(index)-\(String(repeating: "x", count: 1_500))",
        byteCount: 1
      )
    }
    XCTAssertThrowsError(
      try CodexApprovalFileChangeManifest(
        entries: largeEntries,
        totalDiffBytes: largeEntries.count,
        rootDevice: 1,
        rootInode: 2
      )
    ) { error in
      XCTAssertEqual(error as? CodexApprovalEvidenceError, .invalidCollection)
    }
  }

  private func makeEvidence(
    kind: CodexApprovalEvidenceKind = .command,
    authority: CodexApprovalEvidenceAuthority = .correlatedDisplayOnly,
    displayCommand: String? = "/usr/bin/git status",
    displayArguments: [String] = ["Read repository status"],
    digest: String = String(repeating: "a", count: 64),
    fileChangeManifest: CodexApprovalFileChangeManifest? = nil
  ) throws -> CodexApprovalEvidence {
    try CodexApprovalEvidence(
      approvalID: ApprovalID(rawValue: "apr-evidence"),
      kind: kind,
      authority: authority,
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
      evidenceDigest: digest,
      fileChangeManifest: fileChangeManifest
    )
  }

  private func manifestEntry(
    path: String,
    byteCount: Int
  ) throws -> CodexApprovalFileChangeManifestEntry {
    try CodexApprovalFileChangeManifestEntry(
      path: path,
      kind: .update,
      movePath: "Sources/Main.swift",
      diffByteCount: byteCount,
      diffSHA256: String(repeating: "b", count: 64)
    )
  }
}
