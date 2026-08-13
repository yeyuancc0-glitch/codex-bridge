import BridgeDomain
import BridgeReporting
import BridgeSupervisor
import CryptoKit
import Foundation

public enum PipelineTypedEvidenceError: Error, Equatable, Sendable {
  case invalidSupervisorFinalDecision
  case invalidReportMetadata(String)
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
