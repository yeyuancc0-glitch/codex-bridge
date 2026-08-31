import Foundation

extension CodexApprovalWireDecoder {
  public static func decode(_ request: RPCServerRequest) throws -> CodexApprovalRequest {
    let params = try object(request.params, field: "params")
    try validateEvidenceSize(request.params)
    switch request.method {
    case "item/commandExecution/requestApproval":
      return .command(try decodeCommand(requestID: request.id, params: params))
    case "item/fileChange/requestApproval":
      return .fileChange(try decodeFileChange(requestID: request.id, params: params))
    case "item/permissions/requestApproval":
      return .permissions(try decodePermissions(requestID: request.id, params: params))
    default:
      throw CodexApprovalWireError.unsupportedRequestMethod(request.method)
    }
  }

  static func decodeCommand(
    requestID: RequestID,
    params: [String: JSONValue]
  ) throws -> CodexCommandApprovalRequest {
    let correlation = try correlation(requestID: requestID, params: params, permitsCallback: true)
    return CodexCommandApprovalRequest(
      correlation: correlation,
      displayCommand: try optionalString(
        params, key: "command", maximumBytes: CodexApprovalWireLimits.commandBytes),
      displayWorkingDirectory: try optionalCWD(params, key: "cwd"),
      displayActions: try optionalCommandActions(params["commandActions"]),
      reason: try optionalString(params, key: "reason"),
      environmentID: try optionalString(params, key: "environmentId"),
      networkContext: try optionalNetworkContext(params["networkApprovalContext"]),
      proposedExecPolicyAmendment: try optionalStringArray(
        params["proposedExecpolicyAmendment"], field: "proposedExecpolicyAmendment"),
      proposedNetworkPolicyAmendments: try optionalNetworkAmendments(
        params["proposedNetworkPolicyAmendments"])
    )
  }

  static func decodeFileChange(
    requestID: RequestID,
    params: [String: JSONValue]
  ) throws -> CodexFileChangeApprovalRequest {
    CodexFileChangeApprovalRequest(
      correlation: try correlation(requestID: requestID, params: params, permitsCallback: false),
      grantRoot: try optionalString(params, key: "grantRoot"),
      reason: try optionalString(params, key: "reason")
    )
  }

  static func decodePermissions(
    requestID: RequestID,
    params: [String: JSONValue]
  ) throws -> CodexPermissionsApprovalRequest {
    let cwd = try requiredString(params, key: "cwd")
    guard isNormalizedAbsolutePath(cwd) else {
      throw CodexApprovalWireError.invalidField("cwd")
    }
    return CodexPermissionsApprovalRequest(
      correlation: try correlation(requestID: requestID, params: params, permitsCallback: false),
      workingDirectory: cwd,
      permissions: try permissionProfile(params["permissions"]),
      reason: try optionalString(params, key: "reason"),
      environmentID: try optionalString(params, key: "environmentId")
    )
  }

  static func correlation(
    requestID: RequestID,
    params: [String: JSONValue],
    permitsCallback: Bool
  ) throws -> CodexApprovalCorrelation {
    try validate(requestID: requestID)
    let item = CodexApprovalItemKey(
      threadID: try identifier(params, key: "threadId"),
      turnID: try identifier(params, key: "turnId"),
      itemID: try identifier(params, key: "itemId")
    )
    let startedAt = try requiredInteger(params, key: "startedAtMs")
    guard startedAt >= 0 else { throw CodexApprovalWireError.invalidField("startedAtMs") }
    let callback =
      permitsCallback
      ? try optionalIdentifier(params, key: "approvalId")
      : nil
    return CodexApprovalCorrelation(
      requestID: requestID,
      item: item,
      callbackID: callback,
      startedAtMilliseconds: startedAt
    )
  }

  static func optionalCommandActions(_ value: JSONValue?) throws -> [CodexCommandAction]? {
    try commandActions(value, required: false)
  }

  static func commandActions(
    _ value: JSONValue?,
    required: Bool
  ) throws -> [CodexCommandAction]? {
    if value == nil || value == .null {
      if required { throw CodexApprovalWireError.missingField("commandActions") }
      return nil
    }
    let values = try array(value, field: "commandActions")
    try validateArray(values, field: "commandActions")
    return try values.enumerated().map { index, value in
      try commandAction(value, field: "commandActions[\(index)]")
    }
  }

  static func commandAction(
    _ value: JSONValue,
    field: String
  ) throws -> CodexCommandAction {
    let object = try object(value, field: field)
    let type = try requiredString(object, key: "type", maximumBytes: 32)
    let command = try requiredString(
      object, key: "command", maximumBytes: CodexApprovalWireLimits.commandBytes)
    switch type {
    case "read":
      return .read(
        displayCommand: command,
        name: try requiredString(object, key: "name"),
        path: try requiredString(object, key: "path"))
    case "listFiles":
      return .listFiles(
        displayCommand: command,
        path: try optionalString(object, key: "path"))
    case "search":
      return .search(
        displayCommand: command,
        path: try optionalString(object, key: "path"),
        query: try optionalString(object, key: "query"))
    case "unknown":
      return .unknown(displayCommand: command)
    default:
      throw CodexApprovalWireError.unknownDiscriminator(field: "\(field).type", value: type)
    }
  }

  static func optionalNetworkContext(
    _ value: JSONValue?
  ) throws -> CodexNetworkApprovalContext? {
    guard value != nil, value != .null else { return nil }
    let object = try object(value, field: "networkApprovalContext")
    let rawProtocol = try requiredString(object, key: "protocol", maximumBytes: 32)
    guard let networkProtocol = CodexNetworkApprovalProtocol(rawValue: rawProtocol) else {
      throw CodexApprovalWireError.unknownDiscriminator(
        field: "networkApprovalContext.protocol", value: rawProtocol)
    }
    return CodexNetworkApprovalContext(
      host: try requiredString(object, key: "host"),
      protocol: networkProtocol
    )
  }

  static func optionalNetworkAmendments(
    _ value: JSONValue?
  ) throws -> [CodexNetworkPolicyAmendment]? {
    guard value != nil, value != .null else { return nil }
    let values = try array(value, field: "proposedNetworkPolicyAmendments")
    try validateArray(values, field: "proposedNetworkPolicyAmendments")
    return try values.enumerated().map { index, value in
      let field = "proposedNetworkPolicyAmendments[\(index)]"
      let object = try object(value, field: field)
      let rawAction = try requiredString(object, key: "action", maximumBytes: 16)
      guard let action = CodexNetworkPolicyAction(rawValue: rawAction) else {
        throw CodexApprovalWireError.unknownDiscriminator(
          field: "\(field).action", value: rawAction)
      }
      return CodexNetworkPolicyAmendment(
        action: action,
        host: try requiredString(object, key: "host"))
    }
  }
}
