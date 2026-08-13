import Foundation

public enum CodexApprovalEvidenceKind: String, Codable, Equatable, Sendable {
  case command
  case fileChange
  case permissions
}

public enum CodexApprovalEvidenceAuthority: String, Codable, Equatable, Sendable {
  case correlatedDisplayOnly
  case correlatedFileChanges
  case requestedPermissionProfile
}

public enum CodexApprovalEvidenceError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidTimestamp
  case invalidDigest
  case invalidText
  case invalidCollection
}

public struct CodexApprovalEvidence: Codable, Equatable, Sendable {
  public let approvalID: ApprovalID
  public let kind: CodexApprovalEvidenceKind
  public let authority: CodexApprovalEvidenceAuthority
  public let threadID: ThreadID
  public let turnID: TurnID
  public let itemID: String
  public let callbackID: String?
  public let startedAtMilliseconds: Int64
  public let operationTitle: String
  public let displayCommand: String?
  public let displayArguments: [String]
  public let changedPaths: [String]
  public let omittedOperationCount: Int
  public let workingDirectory: String?
  public let reason: String?
  public let evidenceDigest: String

  public init(
    approvalID: ApprovalID,
    kind: CodexApprovalEvidenceKind,
    authority: CodexApprovalEvidenceAuthority,
    threadID: ThreadID,
    turnID: TurnID,
    itemID: String,
    callbackID: String? = nil,
    startedAtMilliseconds: Int64,
    operationTitle: String,
    displayCommand: String? = nil,
    displayArguments: [String] = [],
    changedPaths: [String] = [],
    omittedOperationCount: Int = 0,
    workingDirectory: String? = nil,
    reason: String? = nil,
    evidenceDigest: String
  ) throws {
    guard Self.validIdentifier(approvalID.rawValue), Self.validIdentifier(threadID.rawValue),
      Self.validIdentifier(turnID.rawValue), Self.validIdentifier(itemID),
      callbackID.map(Self.validIdentifier) ?? true
    else { throw CodexApprovalEvidenceError.invalidIdentifier }
    guard startedAtMilliseconds >= 0 else { throw CodexApprovalEvidenceError.invalidTimestamp }
    guard Self.validDigest(evidenceDigest) else {
      throw CodexApprovalEvidenceError.invalidDigest
    }
    guard Self.validText(operationTitle, maximumBytes: 512, required: true),
      Self.validOptionalText(displayCommand, maximumBytes: 8 * 1_024),
      Self.validOptionalText(workingDirectory, maximumBytes: 4 * 1_024),
      Self.validOptionalText(reason, maximumBytes: 2 * 1_024)
    else { throw CodexApprovalEvidenceError.invalidText }
    guard omittedOperationCount >= 0,
      Self.validTexts(displayArguments, maximumCount: 8, maximumBytesEach: 512),
      Self.validTexts(changedPaths, maximumCount: 8, maximumBytesEach: 1_024)
    else { throw CodexApprovalEvidenceError.invalidCollection }

    self.approvalID = approvalID
    self.kind = kind
    self.authority = authority
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.callbackID = callbackID
    self.startedAtMilliseconds = startedAtMilliseconds
    self.operationTitle = operationTitle
    self.displayCommand = displayCommand
    self.displayArguments = displayArguments
    self.changedPaths = changedPaths
    self.omittedOperationCount = omittedOperationCount
    self.workingDirectory = workingDirectory
    self.reason = reason
    self.evidenceDigest = evidenceDigest
  }

  public init(from decoder: any Decoder) throws {
    let value = try Persisted(from: decoder)
    try self.init(
      approvalID: value.approvalID,
      kind: value.kind,
      authority: value.authority,
      threadID: value.threadID,
      turnID: value.turnID,
      itemID: value.itemID,
      callbackID: value.callbackID,
      startedAtMilliseconds: value.startedAtMilliseconds,
      operationTitle: value.operationTitle,
      displayCommand: value.displayCommand,
      displayArguments: value.displayArguments,
      changedPaths: value.changedPaths,
      omittedOperationCount: value.omittedOperationCount,
      workingDirectory: value.workingDirectory,
      reason: value.reason,
      evidenceDigest: value.evidenceDigest
    )
  }

  public func encode(to encoder: any Encoder) throws {
    try Persisted(self).encode(to: encoder)
  }
}

extension CodexApprovalEvidence {
  private struct Persisted: Codable {
    let approvalID: ApprovalID
    let kind: CodexApprovalEvidenceKind
    let authority: CodexApprovalEvidenceAuthority
    let threadID: ThreadID
    let turnID: TurnID
    let itemID: String
    let callbackID: String?
    let startedAtMilliseconds: Int64
    let operationTitle: String
    let displayCommand: String?
    let displayArguments: [String]
    let changedPaths: [String]
    let omittedOperationCount: Int
    let workingDirectory: String?
    let reason: String?
    let evidenceDigest: String

    init(_ value: CodexApprovalEvidence) {
      approvalID = value.approvalID
      kind = value.kind
      authority = value.authority
      threadID = value.threadID
      turnID = value.turnID
      itemID = value.itemID
      callbackID = value.callbackID
      startedAtMilliseconds = value.startedAtMilliseconds
      operationTitle = value.operationTitle
      displayCommand = value.displayCommand
      displayArguments = value.displayArguments
      changedPaths = value.changedPaths
      omittedOperationCount = value.omittedOperationCount
      workingDirectory = value.workingDirectory
      reason = value.reason
      evidenceDigest = value.evidenceDigest
    }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
  }

  private static func validDigest(_ value: String) -> Bool {
    let lowercaseHex = Set("0123456789abcdef")
    return value.count == 64 && value.allSatisfy(lowercaseHex.contains)
  }

  private static func validOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
    value.map { validText($0, maximumBytes: maximumBytes, required: false) } ?? true
  }

  private static func validText(
    _ value: String,
    maximumBytes: Int,
    required: Bool
  ) -> Bool {
    (!required || !value.isEmpty) && value.utf8.count <= maximumBytes && !value.contains("\0")
  }

  private static func validTexts(
    _ values: [String],
    maximumCount: Int,
    maximumBytesEach: Int
  ) -> Bool {
    values.count <= maximumCount
      && values.allSatisfy {
        validText($0, maximumBytes: maximumBytesEach, required: true)
      }
  }
}
