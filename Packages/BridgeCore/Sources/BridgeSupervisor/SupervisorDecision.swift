import Foundation

public enum SupervisorDecisionKind: String, CaseIterable, Codable, Hashable, Sendable {
  case `continue`
  case steer
  case suspend
  case interrupt
  case finalAccept = "final_accept"
  case finalReject = "final_reject"

  fileprivate var reportsIssue: Bool {
    switch self {
    case .steer, .suspend, .interrupt, .finalReject:
      true
    case .continue, .finalAccept:
      false
    }
  }
}

public enum SupervisorRisk: String, CaseIterable, Codable, Sendable {
  case low
  case medium
  case high
  case critical
}

public enum SupervisorDecisionLimits {
  public static let maximumEncodedBytes = 16 * 1024
  public static let maximumSummaryBytes = 2 * 1024
  public static let maximumInstructionBytes = 2 * 1024
  public static let maximumIssueIDBytes = 128
  public static let maximumEvidenceItems = 16
  public static let maximumEvidenceItemBytes = 1024
  public static let maximumRequiredChecks = 16
  public static let maximumRequiredCheckBytes = 1024
}

public enum SupervisorDecisionValidationError: Error, Equatable, Sendable {
  case malformedJSON
  case unknownFields([String])
  case emptyString(field: String)
  case stringTooLarge(field: String, maximumBytes: Int)
  case unsafeControlCharacter(field: String)
  case arrayTooLarge(field: String, maximumCount: Int)
  case invalidConfidence
  case invalidIssueID
  case issueIDRequired
  case unexpectedIssueID
  case instructionRequired
  case unexpectedInstruction
  case scopeViolationRequiresIntervention
  case criticalRiskRequiresIntervention
  case finalAcceptanceHasRequiredChecks
  case encodedPayloadTooLarge(maximumBytes: Int)
  case finalAcceptanceRequiresFinalCheckpoint
}

public struct SupervisorDecision: Codable, Equatable, Sendable {
  public let decision: SupervisorDecisionKind
  public let risk: SupervisorRisk
  public let summary: String
  public let evidence: [String]
  public let instruction: String?
  public let requiredChecks: [String]
  public let scopeViolation: Bool
  public let confidence: Double
  public let issueID: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case decision
    case risk
    case summary
    case evidence
    case instruction
    case requiredChecks = "required_checks"
    case scopeViolation = "scope_violation"
    case confidence
    case issueID = "issue_id"
  }

  public init(
    decision: SupervisorDecisionKind,
    risk: SupervisorRisk,
    summary: String,
    evidence: [String] = [],
    instruction: String? = nil,
    requiredChecks: [String] = [],
    scopeViolation: Bool = false,
    confidence: Double,
    issueID: String? = nil
  ) throws {
    self.decision = decision
    self.risk = risk
    self.summary = summary
    self.evidence = evidence
    self.instruction = instruction
    self.requiredChecks = requiredChecks
    self.scopeViolation = scopeViolation
    self.confidence = confidence
    self.issueID = issueID
    try validateFields()
    _ = try encodedData()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      decision: container.decode(SupervisorDecisionKind.self, forKey: .decision),
      risk: container.decode(SupervisorRisk.self, forKey: .risk),
      summary: container.decode(String.self, forKey: .summary),
      evidence: container.decode([String].self, forKey: .evidence),
      instruction: container.decodeIfPresent(String.self, forKey: .instruction),
      requiredChecks: container.decode([String].self, forKey: .requiredChecks),
      scopeViolation: container.decode(Bool.self, forKey: .scopeViolation),
      confidence: container.decode(Double.self, forKey: .confidence),
      issueID: container.decodeIfPresent(String.self, forKey: .issueID)
    )
  }

  public func encodedData(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
    let data = try encoder.encode(self)
    guard data.count <= SupervisorDecisionLimits.maximumEncodedBytes else {
      throw SupervisorDecisionValidationError.encodedPayloadTooLarge(
        maximumBytes: SupervisorDecisionLimits.maximumEncodedBytes
      )
    }
    return data
  }

  fileprivate func validate(for checkpoint: SupervisorCheckpoint) throws {
    guard decision != .finalAccept || checkpoint.stage == .final else {
      throw SupervisorDecisionValidationError.finalAcceptanceRequiresFinalCheckpoint
    }
  }

  private func validateFields() throws {
    try Self.validate(
      summary,
      field: CodingKeys.summary.rawValue,
      maximumBytes: SupervisorDecisionLimits.maximumSummaryBytes
    )
    try Self.validate(
      evidence,
      field: CodingKeys.evidence.rawValue,
      maximumCount: SupervisorDecisionLimits.maximumEvidenceItems,
      maximumItemBytes: SupervisorDecisionLimits.maximumEvidenceItemBytes
    )
    try Self.validate(
      requiredChecks,
      field: CodingKeys.requiredChecks.rawValue,
      maximumCount: SupervisorDecisionLimits.maximumRequiredChecks,
      maximumItemBytes: SupervisorDecisionLimits.maximumRequiredCheckBytes
    )
    guard confidence.isFinite, (0...1).contains(confidence) else {
      throw SupervisorDecisionValidationError.invalidConfidence
    }
    try validateInstruction()
    try validateIssueID()
    try validateSafetySemantics()
  }

  private func validateInstruction() throws {
    if decision == .steer {
      guard let instruction else {
        throw SupervisorDecisionValidationError.instructionRequired
      }
      try Self.validate(
        instruction,
        field: CodingKeys.instruction.rawValue,
        maximumBytes: SupervisorDecisionLimits.maximumInstructionBytes
      )
      return
    }
    guard instruction == nil else {
      throw SupervisorDecisionValidationError.unexpectedInstruction
    }
  }

  private func validateIssueID() throws {
    guard decision.reportsIssue else {
      guard issueID == nil else {
        throw SupervisorDecisionValidationError.unexpectedIssueID
      }
      return
    }
    guard let issueID else {
      throw SupervisorDecisionValidationError.issueIDRequired
    }
    try Self.validate(
      issueID,
      field: CodingKeys.issueID.rawValue,
      maximumBytes: SupervisorDecisionLimits.maximumIssueIDBytes
    )
    guard issueID.utf8.allSatisfy(Self.isIssueIDByte) else {
      throw SupervisorDecisionValidationError.invalidIssueID
    }
  }

  private func validateSafetySemantics() throws {
    let issueDecisions: Set<SupervisorDecisionKind> = [
      .steer, .suspend, .interrupt, .finalReject,
    ]
    guard !scopeViolation || issueDecisions.contains(decision) else {
      throw SupervisorDecisionValidationError.scopeViolationRequiresIntervention
    }
    let criticalDecisions: Set<SupervisorDecisionKind> = [.suspend, .interrupt, .finalReject]
    guard risk != .critical || criticalDecisions.contains(decision) else {
      throw SupervisorDecisionValidationError.criticalRiskRequiresIntervention
    }
    guard decision != .finalAccept || requiredChecks.isEmpty else {
      throw SupervisorDecisionValidationError.finalAcceptanceHasRequiredChecks
    }
  }

  private static func validate(
    _ values: [String],
    field: String,
    maximumCount: Int,
    maximumItemBytes: Int
  ) throws {
    guard values.count <= maximumCount else {
      throw SupervisorDecisionValidationError.arrayTooLarge(
        field: field,
        maximumCount: maximumCount
      )
    }
    for value in values {
      try validate(value, field: field, maximumBytes: maximumItemBytes)
    }
  }

  private static func validate(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SupervisorDecisionValidationError.emptyString(field: field)
    }
    guard value.utf8.count <= maximumBytes else {
      throw SupervisorDecisionValidationError.stringTooLarge(
        field: field,
        maximumBytes: maximumBytes
      )
    }
    guard !value.unicodeScalars.contains(where: isUnsafeControlScalar) else {
      throw SupervisorDecisionValidationError.unsafeControlCharacter(field: field)
    }
  }

  private static func isUnsafeControlScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0D:
      false
    case 0..<0x20, 0x7F:
      true
    default:
      false
    }
  }

  private static func isIssueIDByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 46, 48...57, 58, 65...90, 95, 97...122:
      true
    default:
      false
    }
  }
}

public enum SupervisorDecisionCodec {
  public static func decode(
    _ data: Data,
    for checkpoint: SupervisorCheckpoint,
    using decoder: JSONDecoder = JSONDecoder()
  ) throws -> SupervisorDecision {
    guard data.count <= SupervisorDecisionLimits.maximumEncodedBytes else {
      throw SupervisorDecisionValidationError.encodedPayloadTooLarge(
        maximumBytes: SupervisorDecisionLimits.maximumEncodedBytes
      )
    }
    try rejectUnknownFields(in: data)
    do {
      let decision = try decoder.decode(SupervisorDecision.self, from: data)
      try decision.validate(for: checkpoint)
      return decision
    } catch let error as SupervisorDecisionValidationError {
      throw error
    } catch {
      throw SupervisorDecisionValidationError.malformedJSON
    }
  }

  private static func rejectUnknownFields(in data: Data) throws {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      throw SupervisorDecisionValidationError.malformedJSON
    }
    let allowed = Set(SupervisorDecision.CodingKeys.allCases.map(\.rawValue))
    let unknown = dictionary.keys.filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
      throw SupervisorDecisionValidationError.unknownFields(unknown)
    }
  }
}
