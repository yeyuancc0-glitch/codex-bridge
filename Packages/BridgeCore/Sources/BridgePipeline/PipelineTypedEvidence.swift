import BridgeDomain
import BridgeReporting
import BridgeSupervisor
import BridgeVerification
import CryptoKit
import Foundation

public enum PipelineTypedEvidenceError: Error, Equatable, Sendable {
  case invalidSupervisorFinalDecision
  case invalidDeterministicPolicyDecision
  case invalidVerificationEvidence(String)
  case invalidReportMetadata(String)
}

public enum PipelineVerificationEvidence: Codable, Equatable, Sendable {
  case run(VerificationRunResult)
  case unavailable(
    id: VerificationCommandIdentifier,
    name: String,
    required: Bool,
    reason: String
  )

  public var id: VerificationCommandIdentifier {
    switch self {
    case .run(let result): result.commandID
    case .unavailable(let id, _, _, _): id
    }
  }

  public var required: Bool {
    switch self {
    case .run(let result): result.required
    case .unavailable(_, _, let required, _): required
    }
  }

  public var reportingEvidence: VerificationEvidence {
    switch self {
    case .run(let result):
      VerificationEvidence(
        id: result.commandID.rawValue,
        name: result.executableName,
        required: result.required,
        status: Self.reportingStatus(result.status),
        exitCode: result.exitCode,
        unavailableReason: Self.unavailableReason(result.status)
      )
    case .unavailable(let id, let name, let required, let reason):
      VerificationEvidence(
        id: id.rawValue,
        name: name,
        required: required,
        status: .unavailable,
        unavailableReason: reason
      )
    }
  }

  public static func notConfigured() throws -> PipelineVerificationEvidence {
    let seed = Data("bridge.pipeline.verification.not-configured.v1".utf8)
    let rawValue = "vcmd_" + SHA256.hash(data: seed).hexString
    guard let id = VerificationCommandIdentifier(rawValue: rawValue) else {
      throw PipelineTypedEvidenceError.invalidVerificationEvidence("id")
    }
    return try makeUnavailable(
      id: id,
      name: "Project verification",
      required: false,
      reason: "No verification commands are registered for this project."
    )
  }

  public static func makeUnavailable(
    id: VerificationCommandIdentifier,
    name: String,
    required: Bool,
    reason: String
  ) throws -> PipelineVerificationEvidence {
    try validate(name, field: "name", maximum: 512)
    try validate(reason, field: "reason", maximum: 4_096)
    return .unavailable(id: id, name: name, required: required, reason: reason)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case result
    case id
    case name
    case required
    case reason
  }

  private enum Kind: String, Codable {
    case run
    case unavailable
  }

  public init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self),
      container.contains(.kind)
    else {
      self = .run(try VerificationRunResult(from: decoder))
      return
    }
    switch try container.decode(Kind.self, forKey: .kind) {
    case .run:
      self = .run(try container.decode(VerificationRunResult.self, forKey: .result))
    case .unavailable:
      self = try Self.makeUnavailable(
        id: container.decode(VerificationCommandIdentifier.self, forKey: .id),
        name: container.decode(String.self, forKey: .name),
        required: container.decode(Bool.self, forKey: .required),
        reason: container.decode(String.self, forKey: .reason)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .run(let result):
      try container.encode(Kind.run, forKey: .kind)
      try container.encode(result, forKey: .result)
    case .unavailable(let id, let name, let required, let reason):
      try container.encode(Kind.unavailable, forKey: .kind)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(required, forKey: .required)
      try container.encode(reason, forKey: .reason)
    }
  }

  private static func validate(_ value: String, field: String, maximum: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= maximum, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil
    else { throw PipelineTypedEvidenceError.invalidVerificationEvidence(field) }
  }

  private static func reportingStatus(_ status: VerificationRunStatus) -> VerificationStatus {
    switch status {
    case .passed: .passed
    case .failed, .timedOut, .outputLimitExceeded: .failed
    case .cancelled, .policyDenied, .localApprovalRequired, .rootUnavailable, .launchFailed:
      .unavailable
    }
  }

  private static func unavailableReason(_ status: VerificationRunStatus) -> String? {
    switch status {
    case .cancelled: "Verification was cancelled."
    case .policyDenied: "Verification was denied by policy."
    case .localApprovalRequired: "Verification requires unconsumed local approval."
    case .rootUnavailable: "The registered project root was unavailable."
    case .launchFailed: "The verification process could not be launched."
    case .passed, .failed, .timedOut, .outputLimitExceeded: nil
    }
  }
}

public struct PipelineSupervisorFinalEvidence: Codable, Equatable, Sendable {
  public let scope: TaskEvidenceScope
  public let checkpointStage: SupervisorCheckpointStage
  public let decision: SupervisorDecision
  public let decisionDigest: String

  public init(
    scope: TaskEvidenceScope,
    checkpointStage: SupervisorCheckpointStage,
    decision: SupervisorDecision
  ) throws {
    guard checkpointStage == .final, decision.decision == .finalAccept,
      !decision.scopeViolation, decision.requiredChecks.isEmpty
    else {
      throw PipelineTypedEvidenceError.invalidSupervisorFinalDecision
    }
    self.scope = scope
    self.checkpointStage = checkpointStage
    self.decision = decision
    decisionDigest = try Self.digest(decision)
  }

  private enum CodingKeys: String, CodingKey {
    case scope
    case checkpointStage
    case decision
    case decisionDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let scope = try container.decode(TaskEvidenceScope.self, forKey: .scope)
    let checkpointStage = try container.decode(
      SupervisorCheckpointStage.self,
      forKey: .checkpointStage
    )
    let decision = try container.decode(SupervisorDecision.self, forKey: .decision)
    try self.init(scope: scope, checkpointStage: checkpointStage, decision: decision)
    guard decisionDigest == (try container.decode(String.self, forKey: .decisionDigest)) else {
      throw PipelineTypedEvidenceError.invalidSupervisorFinalDecision
    }
  }

  private static func digest(_ decision: SupervisorDecision) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try decision.encodedData(using: encoder)).hexString
  }
}

public struct PipelineDeterministicPolicyFinalEvidence: Codable, Equatable, Sendable {
  public let scope: TaskEvidenceScope
  public let policy: PolicyEvidence
  public let userOverride: UserCompletionOverride
  public let decisionDigest: String

  public init(
    scope: TaskEvidenceScope,
    policy: PolicyEvidence,
    userOverride: UserCompletionOverride
  ) throws {
    guard policy.evaluationCompleted, policy.unresolvedBlockers.isEmpty,
      !userOverride.decisionID.isEmpty,
      !userOverride.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PipelineTypedEvidenceError.invalidDeterministicPolicyDecision
    }
    self.scope = scope
    self.policy = policy
    self.userOverride = userOverride
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    decisionDigest =
      SHA256.hash(
        data: try encoder.encode(StableDigestInput(policy: policy, userOverride: userOverride))
      ).hexString
  }

  private struct StableDigestInput: Codable {
    let policy: PolicyEvidence
    let userOverride: UserCompletionOverride
  }

  private enum CodingKeys: String, CodingKey {
    case scope
    case policy
    case userOverride
    case decisionDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      scope: container.decode(TaskEvidenceScope.self, forKey: .scope),
      policy: container.decode(PolicyEvidence.self, forKey: .policy),
      userOverride: container.decode(UserCompletionOverride.self, forKey: .userOverride)
    )
    guard decisionDigest == (try container.decode(String.self, forKey: .decisionDigest)) else {
      throw PipelineTypedEvidenceError.invalidDeterministicPolicyDecision
    }
  }
}

public struct PipelineReportMetadataEvidence: Codable, Equatable, Sendable {
  public let scope: TaskEvidenceScope
  public let schemaVersion: UInt16
  public let status: FinalReportStatus
  public let reportJSON: Data
  public let reportDigest: String
  public let byteCount: Int
  public let supervisorDecisionDigest: String
  public let reportReference: String

  public init(
    scope: TaskEvidenceScope,
    schemaVersion: UInt16,
    status: FinalReportStatus,
    reportJSON: Data,
    supervisorDecisionDigest: String
  ) throws {
    guard schemaVersion > 0 else {
      throw PipelineTypedEvidenceError.invalidReportMetadata("schemaVersion")
    }
    guard status == .completed else {
      throw PipelineTypedEvidenceError.invalidReportMetadata("status")
    }
    guard !reportJSON.isEmpty, reportJSON.count <= ReportingLimits.standard.maximumJSONBytes else {
      throw PipelineTypedEvidenceError.invalidReportMetadata("byteCount")
    }
    guard Self.isDigest(supervisorDecisionDigest) else {
      throw PipelineTypedEvidenceError.invalidReportMetadata("supervisorDecisionDigest")
    }
    self.scope = scope
    self.schemaVersion = schemaVersion
    self.status = status
    self.reportJSON = reportJSON
    reportDigest = SHA256.hash(data: reportJSON).hexString
    byteCount = reportJSON.count
    self.supervisorDecisionDigest = supervisorDecisionDigest
    reportReference = "report:sha256:\(reportDigest)"
  }

  private enum CodingKeys: String, CodingKey {
    case scope
    case schemaVersion
    case status
    case reportJSON
    case reportDigest
    case byteCount
    case supervisorDecisionDigest
    case reportReference
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      scope: container.decode(TaskEvidenceScope.self, forKey: .scope),
      schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
      status: container.decode(FinalReportStatus.self, forKey: .status),
      reportJSON: container.decode(Data.self, forKey: .reportJSON),
      supervisorDecisionDigest: container.decode(
        String.self,
        forKey: .supervisorDecisionDigest
      )
    )
    guard reportDigest == (try container.decode(String.self, forKey: .reportDigest)),
      byteCount == (try container.decode(Int.self, forKey: .byteCount)),
      reportReference == (try container.decode(String.self, forKey: .reportReference))
    else {
      throw PipelineTypedEvidenceError.invalidReportMetadata("reportReference")
    }
  }

  private static func isDigest(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
      }
  }
}

extension Digest {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
