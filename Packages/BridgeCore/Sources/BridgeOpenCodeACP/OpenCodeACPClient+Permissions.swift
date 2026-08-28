import BridgeACP
import BridgeAgentCore
import Foundation

extension OpenCodeACPClient {
  public func resolvePermission(
    approvalID: String,
    optionID: String
  ) async throws {
    try requireInitialized()
    try validateIdentifier(approvalID)
    try validateIdentifier(optionID)
    guard let request = pendingPermissions[approvalID] else {
      throw AgentRuntimeError.approvalUnavailable(approvalID)
    }
    guard request.options.contains(where: { $0.id == optionID }) else {
      throw AgentRuntimeError.approvalUnavailable(optionID)
    }
    try requireSession(request.sessionID)
    pendingPermissions.removeValue(forKey: approvalID)
    do {
      try await send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: optionID)
        )
      )
    } catch {
      await failConnection(error)
      throw error
    }
  }

  func handleServerRequest(
    id: ACPRequestID,
    method: String,
    params: ACPJSONValue?
  ) async {
    guard method == "session/request_permission" else {
      try? await send(
        ACPWireMessage(
          id: id,
          error: ACPWireError(code: -32601, message: "Method not found")
        )
      )
      return
    }

    do {
      let request = try Self.parsePermissionRequest(
        approvalID: nextApprovalID(),
        id: id,
        params: params
      )
      try requireSession(request.sessionID)
      guard pendingPermissions[request.approvalID] == nil else {
        throw AgentRuntimeError.approvalUnavailable(request.approvalID)
      }
      pendingPermissions[request.approvalID] = request
      yield(.permissionRequested(request))
    } catch {
      try? await send(
        ACPWireMessage(
          id: id,
          error: ACPWireError(code: -32602, message: "Invalid permission request")
        )
      )
    }
  }

  private func nextApprovalID() throws -> String {
    for _ in 0..<8 {
      let value = "opencode-\(UUID().uuidString.lowercased())"
      if pendingPermissions[value] == nil { return value }
    }
    throw AgentRuntimeError.approvalUnavailable("id")
  }

  private static func parsePermissionRequest(
    approvalID: String,
    id: ACPRequestID,
    params: ACPJSONValue?
  ) throws -> OpenCodeACPPermissionRequest {
    guard let object = params?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let toolCall = object["toolCall"]?.objectValue,
      let toolCallID = toolCall["toolCallId"]?.stringValue,
      let rawOptions = object["options"]?.arrayValue
    else {
      throw OpenCodeACPError.invalidMessage
    }
    try validateIdentifier(sessionID)
    try validateIdentifier(toolCallID)
    guard !rawOptions.isEmpty, rawOptions.count <= 16 else {
      throw OpenCodeACPError.invalidMessage
    }
    let options = try rawOptions.map { value -> AgentApprovalOption in
      guard let option = value.objectValue,
        let optionID = option["optionId"]?.stringValue,
        let name = option["name"]?.stringValue,
        let kind = option["kind"]?.stringValue
      else {
        throw OpenCodeACPError.invalidMessage
      }
      return try AgentApprovalOption(id: optionID, name: name, kind: kind)
    }
    guard !options.isEmpty else { throw OpenCodeACPError.invalidMessage }
    let title = toolCall["title"]?.stringValue ?? "OpenCode tool request"
    guard !title.isEmpty, title.utf8.count <= 1_024,
      !title.contains("\0")
    else {
      throw OpenCodeACPError.invalidMessage
    }
    return OpenCodeACPPermissionRequest(
      approvalID: approvalID,
      requestID: id,
      sessionID: sessionID,
      toolCallID: toolCallID,
      title: title,
      kind: toolCall["kind"]?.stringValue,
      rawInput: toolCall["rawInput"],
      options: options
    )
  }

  private static func permissionSelection(optionID: String) -> ACPJSONValue {
    return .object([
      "outcome": .object([
        "outcome": .string("selected"),
        "optionId": .string(optionID),
      ])
    ])
  }
}
