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
}
