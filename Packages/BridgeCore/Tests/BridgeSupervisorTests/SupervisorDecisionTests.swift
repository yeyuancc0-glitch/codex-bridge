import Foundation
import XCTest

@testable import BridgeSupervisor

final class SupervisorDecisionTests: XCTestCase {
  func testDecisionVocabularyIsClosed() {
    XCTAssertEqual(
      Set(SupervisorDecisionKind.allCases.map(\.rawValue)),
      ["continue", "steer", "suspend", "interrupt", "final_accept", "final_reject"]
    )
  }

  func testStrictCodecRoundTripsValidSteer() throws {
    let checkpoint = try makeCheckpoint(sequence: 1)
    let decision = try makeDecision(
      .steer,
      instruction: "Limit the change to Sources/BridgeSupervisor.",
      issueID: "scope.expansion"
    )

    let decoded = try SupervisorDecisionCodec.decode(decision.encodedData(), for: checkpoint)

    XCTAssertEqual(decoded, decision)
  }

  func testInstructionIsRequiredOnlyForSteer() throws {
    XCTAssertThrowsError(
      try makeDecision(.steer, issueID: "missing.instruction")
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .instructionRequired)
    }
    XCTAssertThrowsError(
      try makeDecision(.continue, instruction: "Unexpected")
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .unexpectedInstruction)
    }
    XCTAssertNoThrow(try makeDecision(.continue))
  }

  func testIssueIDIsStableAndBoundedForProblemDecisions() throws {
    XCTAssertThrowsError(
      try makeDecision(.suspend)
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .issueIDRequired)
    }
    XCTAssertThrowsError(
      try makeDecision(.interrupt, issueID: "contains spaces")
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .invalidIssueID)
    }
    XCTAssertThrowsError(
      try makeDecision(.continue, issueID: "unexpected")
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .unexpectedIssueID)
    }
  }

  func testConfidenceStringsArraysAndTotalEncodingHaveHardLimits() throws {
    XCTAssertThrowsError(
      try makeDecision(.continue, confidence: .nan)
    ) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .invalidConfidence)
    }
    XCTAssertThrowsError(
      try makeDecision(.continue, summary: String(repeating: "a", count: 2049))
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .stringTooLarge(field: "summary", maximumBytes: 2048)
      )
    }
    XCTAssertThrowsError(
      try makeDecision(.continue, evidence: Array(repeating: "e", count: 17))
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .arrayTooLarge(field: "evidence", maximumCount: 16)
      )
    }
    let largeItems = Array(repeating: String(repeating: "x", count: 1000), count: 16)
    XCTAssertThrowsError(
      try makeDecision(.continue, evidence: largeItems, requiredChecks: largeItems)
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .encodedPayloadTooLarge(maximumBytes: 16 * 1024)
      )
    }
  }

  func testUnsafeControlCharactersAreRejected() {
    XCTAssertThrowsError(
      try makeDecision(
        .steer,
        instruction: "safe\u{0000}unsafe",
        issueID: "unsafe.instruction"
      )
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .unsafeControlCharacter(field: "instruction")
      )
    }
  }

  func testCodecRejectsUnknownFieldsAndInvalidRisk() throws {
    let checkpoint = try makeCheckpoint(sequence: 1)
    let unknown = Data(
      """
      {"decision":"continue","risk":"low","summary":"ok","evidence":[],"instruction":null,"required_checks":[],"scope_violation":false,"confidence":0.8,"extra":true}
      """.utf8
    )
    XCTAssertThrowsError(try SupervisorDecisionCodec.decode(unknown, for: checkpoint)) { error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .unknownFields(["extra"]))
    }

    let invalidRisk = Data(
      """
      {"decision":"continue","risk":"extreme","summary":"ok","evidence":[],"instruction":null,"required_checks":[],"scope_violation":false,"confidence":0.8}
      """.utf8
    )
    XCTAssertThrowsError(try SupervisorDecisionCodec.decode(invalidRisk, for: checkpoint)) {
      error in
      XCTAssertEqual(error as? SupervisorDecisionValidationError, .malformedJSON)
    }
  }

  func testFinalAcceptanceRequiresFinalCheckpoint() throws {
    let decision = try makeDecision(.finalAccept)
    let progress = try makeCheckpoint(sequence: 1)
    let final = try makeCheckpoint(sequence: 2, stage: .final)

    XCTAssertThrowsError(try SupervisorDecisionCodec.decode(decision.encodedData(), for: progress))
    {
      error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .finalAcceptanceRequiresFinalCheckpoint
      )
    }
    XCTAssertEqual(
      try SupervisorDecisionCodec.decode(decision.encodedData(), for: final),
      decision
    )
  }

  func testSafetySemanticsRejectContradictoryModelDecisions() {
    XCTAssertThrowsError(
      try makeDecision(.continue, scopeViolation: true)
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .scopeViolationRequiresIntervention
      )
    }
    XCTAssertThrowsError(
      try makeDecision(
        .steer,
        instruction: "Correct the issue.",
        risk: .critical,
        issueID: "critical.issue"
      )
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .criticalRiskRequiresIntervention
      )
    }
    XCTAssertThrowsError(
      try makeDecision(.finalAccept, requiredChecks: ["Run tests"])
    ) { error in
      XCTAssertEqual(
        error as? SupervisorDecisionValidationError,
        .finalAcceptanceHasRequiredChecks
      )
    }
  }

  func testOutputSchemaEncodesAsFoundationJSON() throws {
    let data = try SupervisorOutputSchema.encodedDecisionSchema()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let properties = try XCTUnwrap(object["properties"] as? [String: Any])
    let decision = try XCTUnwrap(properties["decision"] as? [String: Any])
    XCTAssertEqual(
      Set(try XCTUnwrap(decision["enum"] as? [String])),
      Set(SupervisorDecisionKind.allCases.map(\.rawValue))
    )
    XCTAssertEqual(object["additionalProperties"] as? Bool, false)
  }
}

func makeCheckpoint(
  sequence: UInt64,
  turnID: String = "turn-1",
  stage: SupervisorCheckpointStage = .progress
) throws -> SupervisorCheckpoint {
  try SupervisorCheckpoint(
    sequence: sequence,
    taskID: "task-1",
    turnID: turnID,
    stage: stage,
    triggers: stage == .final ? [.completionClaimed] : [.planChanged],
    content: SupervisorCheckpointContent(
      taskContract: "Implement the bounded Supervisor core.",
      executionModel: "gpt-test",
      executionEffort: "medium",
      remainingAutomaticSteers: 5
    )
  )
}

func makeDecision(
  _ kind: SupervisorDecisionKind,
  summary: String = "The execution remains within the task contract.",
  evidence: [String] = [],
  instruction: String? = nil,
  requiredChecks: [String] = [],
  scopeViolation: Bool = false,
  risk: SupervisorRisk = .low,
  confidence: Double = 0.9,
  issueID: String? = nil
) throws -> SupervisorDecision {
  try SupervisorDecision(
    decision: kind,
    risk: risk,
    summary: summary,
    evidence: evidence,
    instruction: instruction,
    requiredChecks: requiredChecks,
    scopeViolation: scopeViolation,
    confidence: confidence,
    issueID: issueID
  )
}
