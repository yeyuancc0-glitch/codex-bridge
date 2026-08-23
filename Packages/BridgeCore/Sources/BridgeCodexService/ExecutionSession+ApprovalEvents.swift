import BridgeCodexRPC
import Foundation

extension ExecutionSession {
  func receive(_ request: RPCServerRequest) async {
    guard Self.supportedApprovalMethods.contains(request.method) else {
      if Self.legacyApprovalMethods.contains(request.method) {
        await rejectLegacyApproval(request)
        await fail(
          code: "legacy_approval_unsupported",
          summary: "Codex requested an approval without authoritative Turn correlation."
        )
        return
      }
      try? await client.respond(
        to: request.id,
        errorCode: -32601,
        message: "Method not supported by Codex Bridge."
      )
      return
    }

    guard binding != nil else {
      guard deferredRequests.count < configuration.maximumPendingApprovals else {
        try? await client.respond(
          to: request.id,
          errorCode: -32000,
          message: "Codex Bridge approval capacity exceeded."
        )
        await fail(code: "approval_capacity", summary: "Codex approval capacity was exceeded.")
        return
      }
      deferredRequests.append(request)
      return
    }
    await processServerRequest(request)
  }

  func processServerRequest(_ rpcRequest: RPCServerRequest) async {
    guard binding != nil else {
      await rejectInvalidApproval(rpcRequest)
      return
    }
    do {
      let decoded = try CodexApprovalWireDecoder.decode(rpcRequest)
      let correlation = decoded.correlation
      let requestKey = ApprovalRequestKey(
        method: rpcRequest.method,
        threadID: correlation.item.threadID,
        turnID: correlation.item.turnID,
        itemID: correlation.item.itemID,
        callbackID: correlation.callbackID
      )
      guard
        let approvalBinding = try? ExecutionBinding(
          threadID: correlation.item.threadID,
          turnID: correlation.item.turnID
        ),
        isKnownBinding(approvalBinding),
        let itemEvidence = knownItems[correlation.item],
        !usedApprovalRequests.contains(requestKey),
        usedApprovalRequests.count < configuration.maximumKnownItems,
        pendingApprovals.count < configuration.maximumPendingApprovals
      else {
        throw ExecutionServiceError.protocolViolation("approval correlation")
      }
      let id = "apr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let prepared = try ExecutionApprovalBuilder.build(
        approvalID: id,
        taskID: taskID,
        binding: approvalBinding,
        request: decoded,
        itemEvidence: itemEvidence,
        rawParameters: rpcRequest.params,
        projectRoot: projectRoot,
        limits: approvalLimits
      )
      usedApprovalRequests.insert(requestKey)
      pendingApprovals[id] = PendingApproval(
        rpcRequestID: rpcRequest.id,
        response: prepared.response,
        request: prepared.request
      )
      yield(.approvalRequested(prepared.request))
    } catch {
      await rejectInvalidApproval(rpcRequest)
    }
  }

  private static let supportedApprovalMethods: Set<String> = [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
  ]

  private static let legacyApprovalMethods: Set<String> = [
    "applyPatchApproval",
    "execCommandApproval",
  ]

  private func rejectInvalidApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      errorCode: -32602,
      message: "Approval request rejected by Codex Bridge."
    )
    await fail(
      code: "invalid_approval_request",
      summary: "Codex emitted an invalid approval request."
    )
  }

  private func rejectLegacyApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      result: .object(["decision": .string("abort")])
    )
  }
}
