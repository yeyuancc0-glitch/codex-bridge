import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func servicePendingDirectApprovals(
    deadline: ContinuousClock.Instant
  ) async throws -> [PendingDirectApproval] {
    try Self.checkDeadline(deadline)
    return await approvals.pendingApprovals()
  }

  public func serviceDirectApprovalMode(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceDirectApprovalMode {
    try Self.checkDeadline(deadline)
    return try await settings.directApprovalMode()
  }

  public func serviceSetDirectApprovalMode(
    _ mode: ServiceDirectApprovalMode,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setDirectApprovalMode(mode)
  }

  public func serviceApproveDirectApproval(
    approvalID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    try Self.checkDeadline(deadline)
    guard !approvalID.isEmpty, approvalID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.approvalExpired
    }
    return await approvals.approve(approvalID: approvalID)
  }

  public func serviceDenyDirectApproval(
    approvalID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    try Self.checkDeadline(deadline)
    guard !approvalID.isEmpty, approvalID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.approvalExpired
    }
    return await approvals.deny(approvalID: approvalID)
  }

  func requireDirectApproval(
    project: ServiceProjectRecord,
    kind: DirectApprovalKind,
    summary: String,
    payload: some Encodable,
    clientRequestID: String?
  ) async throws {
    if try await settings.directApprovalMode() == .auto { return }
    let digest = DirectActionApprovalCenter.payloadDigest(payload)
    let granted = await approvals.consume(payloadDigest: digest, clientRequestID: clientRequestID)
    if granted { return }
    let approvalID = await approvals.request(
      projectID: project.id.rawValue,
      kind: kind,
      summary: summary,
      payloadDigest: digest,
      clientRequestID: clientRequestID
    )
    throw BridgeMCPQueryError.approvalRequired(approvalID: approvalID)
  }
}
