import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func approvedDirectProject(
    projectID: String,
    kind: DirectApprovalKind,
    summary: String,
    payload: some Encodable,
    clientRequestID: String?
  ) async throws -> ServiceProjectRecord {
    let project = try await writableProject(projectID)
    try await requireDirectApproval(
      project: project,
      kind: kind,
      summary: summary,
      payload: payload,
      clientRequestID: clientRequestID
    )
    return project
  }

  func writableProject(_ projectID: String) async throws -> ServiceProjectRecord {
    let project = try await readableProject(projectID)
    guard project.accessPolicy.write != .denied else {
      throw BridgeMCPQueryError.writeNotAllowed
    }
    return project
  }

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

  public func serviceTaskStartApprovalMode(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceTaskStartApprovalMode {
    try Self.checkDeadline(deadline)
    return try await settings.taskStartApprovalMode()
  }

  public func serviceSetTaskStartApprovalMode(
    _ mode: ServiceTaskStartApprovalMode,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setTaskStartApprovalMode(mode)
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
    if await approvals.denialIsActive(
      payloadDigest: digest,
      clientRequestID: clientRequestID
    ) {
      throw BridgeMCPQueryError.approvalDenied
    }
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
