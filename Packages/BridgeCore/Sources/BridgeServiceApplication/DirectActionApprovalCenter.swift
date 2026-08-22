import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Crypto
import Foundation

public enum DirectApprovalKind: String, Codable, Sendable {
  case fileWrite = "file_write"
  case pathAction = "path_action"
  case command = "command"
  case network = "network"
}

public struct PendingDirectApproval: Codable, Equatable, Sendable {
  public let approvalID: String
  public let projectID: String
  public let kind: DirectApprovalKind
  public let summary: String
  public let createdAt: Date

  public init(
    approvalID: String,
    projectID: String,
    kind: DirectApprovalKind,
    summary: String,
    createdAt: Date
  ) {
    self.approvalID = approvalID
    self.projectID = projectID
    self.kind = kind
    self.summary = summary
    self.createdAt = createdAt
  }
}

public enum DirectApprovalError: Error, Equatable, Sendable {
  case expired
  case denied
  case unknownApproval
  case grantConsumed
}

public actor DirectActionApprovalCenter {
  private struct Pending {
    let projectID: String
    let kind: DirectApprovalKind
    let summary: String
    let key: String
    let createdAt: Date
  }

  private var pendingByID: [String: Pending] = [:]
  private var grantKeys: [String: Date] = [:]
  private var deniedKeys: [String: Date] = [:]
  public let approvalLifetime: TimeInterval
  public let denyLifetime: TimeInterval

  public init(
    approvalLifetime: TimeInterval = 300,
    denyLifetime: TimeInterval = 30
  ) {
    self.approvalLifetime = approvalLifetime
    self.denyLifetime = denyLifetime
  }

  public static func payloadDigest(_ payload: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(payload)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  public func request(
    projectID: String,
    kind: DirectApprovalKind,
    summary: String,
    payloadDigest: String,
    clientRequestID: String?
  ) -> String {
    expireIfNeeded()
    let key = Self.key(payloadDigest: payloadDigest, clientRequestID: clientRequestID)
    if let deniedAt = deniedKeys[key] {
      if Date().timeIntervalSince(deniedAt) < denyLifetime {
        // A denial is a cooldown, not another approval request. Keep the
        // source-compatible String return while returning an unapprovable
        // marker to legacy callers; no pending item is created.
        return Self.deniedApprovalID(for: key)
      }
      deniedKeys[key] = nil
    }
    let approvalID = "appr-\(UUID().uuidString)"
    pendingByID[approvalID] = Pending(
      projectID: projectID,
      kind: kind,
      summary: summary,
      key: key,
      createdAt: Date()
    )
    return approvalID
  }

  public func pendingApprovals() -> [PendingDirectApproval] {
    expireIfNeeded()
    return pendingByID.map { id, pending in
      PendingDirectApproval(
        approvalID: id,
        projectID: pending.projectID,
        kind: pending.kind,
        summary: pending.summary,
        createdAt: pending.createdAt
      )
    }
    .sorted { $0.createdAt > $1.createdAt }
  }

  public func approve(approvalID: String) -> Bool {
    expireIfNeeded()
    guard let pending = pendingByID[approvalID] else { return false }
    pendingByID[approvalID] = nil
    deniedKeys[pending.key] = nil
    grantKeys[pending.key] = Date()
    return true
  }

  public func deny(approvalID: String) -> Bool {
    expireIfNeeded()
    guard let pending = pendingByID[approvalID] else { return false }
    pendingByID[approvalID] = nil
    deniedKeys[pending.key] = Date()
    return true
  }

  public func consume(
    payloadDigest: String,
    clientRequestID: String?
  ) -> Bool {
    expireIfNeeded()
    let key = Self.key(payloadDigest: payloadDigest, clientRequestID: clientRequestID)
    guard grantKeys.removeValue(forKey: key) != nil else { return false }
    return true
  }

  public func denialIsActive(
    payloadDigest: String,
    clientRequestID: String?
  ) -> Bool {
    expireIfNeeded()
    let key = Self.key(payloadDigest: payloadDigest, clientRequestID: clientRequestID)
    return deniedKeys[key] != nil
  }

  public func cancelAll() {
    pendingByID = [:]
    grantKeys = [:]
    deniedKeys = [:]
  }

  private func expireIfNeeded() {
    let now = Date()
    pendingByID = pendingByID.filter { _, pending in
      now.timeIntervalSince(pending.createdAt) < approvalLifetime
    }
    grantKeys = grantKeys.filter { _, grantedAt in
      now.timeIntervalSince(grantedAt) < approvalLifetime
    }
    deniedKeys = deniedKeys.filter { _, date in
      now.timeIntervalSince(date) < denyLifetime
    }
  }

  private static func key(payloadDigest: String, clientRequestID: String?) -> String {
    "\(payloadDigest)|\(clientRequestID ?? "")"
  }

  private static func deniedApprovalID(for key: String) -> String {
    let digest = SHA256.hash(data: Data(key.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "denied-\(digest.prefix(16))"
  }
}
