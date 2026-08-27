import Foundation
import XCTest

@testable import BridgeMCP

final class MCPToolErrorPresentationTests: XCTestCase {
  func testPatchErrorsPublishActionableStructuredMetadata() {
    let cases: [(BridgeMCPQueryError, String, MCPToolErrorCategory, Bool, String)] = [
      (.invalidPatchSyntax, "invalid_patch_syntax", .callerError, false, "fix_patch_syntax"),
      (
        .patchContextNotFound, "patch_context_not_found", .stateConflict, true,
        "read_file_and_retry_smaller_patch"
      ),
      (
        .patchContextNonUnique, "patch_context_non_unique", .stateConflict, true,
        "read_file_and_retry_smaller_patch"
      ),
      (
        .patchContextStale, "patch_context_stale", .stateConflict, true,
        "read_file_and_retry_smaller_patch"
      ),
    ]

    for (error, code, category, retryable, nextAction) in cases {
      let value = error.toolError
      XCTAssertEqual(value.code, code)
      XCTAssertEqual(value.category, category)
      XCTAssertEqual(value.retryable, retryable)
      XCTAssertEqual(value.nextAction, nextAction)
    }
  }

  func testCommandDenialsKeepPolicyReasonMachineReadable() {
    let cases: [(MCPCommandDenialReason, MCPToolErrorCategory, String)] = [
      (.commandNotRegistered, .policyDenied, "list_project_commands"),
      (.invalidArguments, .callerError, "fix_command_arguments"),
      (.commandModeDenied, .policyDenied, "do_not_run_direct_commands"),
      (.networkDenied, .policyDenied, "use_command_without_network"),
      (.writeDenied, .policyDenied, "request_project_write_access"),
      (.blacklisted, .policyDenied, "do_not_retry_command"),
    ]

    for (reason, category, nextAction) in cases {
      let value = BridgeMCPQueryError.commandDenied(reason.rawValue).toolError
      XCTAssertEqual(value.code, reason.rawValue)
      XCTAssertEqual(value.category, category)
      XCTAssertFalse(value.retryable)
      XCTAssertEqual(value.nextAction, nextAction)
    }
  }

  func testLegacyCommandDenialRemainsSourceCompatible() {
    let value = BridgeMCPQueryError.commandDenied("legacy reason").toolError

    XCTAssertEqual(value.code, "command_denied")
    XCTAssertEqual(value.category, .policyDenied)
    XCTAssertEqual(value.nextAction, "list_project_commands")
  }

  func testMutationStateErrorsDoNotProduceSuccessReceipts() {
    let binary = BridgeMCPQueryError.binaryContentUnsupported.toolError
    XCTAssertEqual(binary.code, "binary_content_unsupported")
    XCTAssertEqual(binary.nextAction, "use_utf8_text_file")

    let partial = BridgeMCPQueryError.patchPartialCommit(
      MCPPartialCommit(changedFiles: ["a.txt"], rollbackStatus: "rollback_failed")
    ).toolError
    XCTAssertEqual(partial.code, "patch_partial_commit")
    XCTAssertEqual(partial.category, .stateConflict)
    XCTAssertFalse(partial.retryable)
    XCTAssertEqual(partial.data?["changed_files"], "a.txt")
    XCTAssertEqual(partial.data?["rollback_status"], "rollback_failed")
  }

  func testLegacyErrorPayloadStillDecodes() throws {
    let value = try JSONDecoder().decode(
      MCPToolErrorDTO.self,
      from: Data(#"{"code":"legacy","message":"Legacy error","retryable":true}"#.utf8)
    )

    XCTAssertEqual(value.code, "legacy")
    XCTAssertEqual(value.category, .infrastructureFailure)
    XCTAssertEqual(value.nextAction, "inspect_error")
    XCTAssertTrue(value.retryable)
  }

  func testRevisionConflictPreservesStructuredContext() {
    let value = BridgeMCPQueryError.revisionConflict(
      RevisionConflictDetail(
        relativePath: "Sources/App.swift",
        currentSHA256: String(repeating: "a", count: 64),
        changedSinceRevision: true,
        removedLines: ["old"],
        addedLines: ["new"],
        truncated: false,
        byteCount: 8
      )
    ).toolError

    XCTAssertEqual(value.category, .stateConflict)
    XCTAssertEqual(value.nextAction, "read_file_and_retry")
    XCTAssertEqual(value.data?["relative_path"], "Sources/App.swift")
  }
}
