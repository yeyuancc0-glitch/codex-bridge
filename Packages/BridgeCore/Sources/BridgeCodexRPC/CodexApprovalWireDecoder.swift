import Foundation

public enum CodexApprovalWireDecoder {
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

  public static func decodeItemStarted(
    _ notification: RPCNotification
  ) throws -> CodexApprovalItemEvidence {
    guard notification.method == "item/started" else {
      throw CodexApprovalWireError.unsupportedRequestMethod(notification.method)
    }
    try validateEvidenceSize(notification.params)
    let params = try object(notification.params, field: "params")
    let item = try object(params["item"], field: "item")
    let type = try requiredString(item, key: "type", maximumBytes: 64)
    switch type {
    case "commandExecution":
      return .commandExecution(try decodeCommandEvidence(params: params, item: item))
    case "fileChange":
      return .fileChange(try decodeFileEvidence(params: params, item: item))
    default:
      throw CodexApprovalWireError.unsupportedItemType(type)
    }
  }

  private static func decodeCommand(
    requestID: RequestID,
    params: [String: JSONValue]
  ) throws -> CodexCommandApprovalRequest {
    let correlation = try correlation(requestID: requestID, params: params, permitsCallback: true)
    return CodexCommandApprovalRequest(
      correlation: correlation,
      displayCommand: try optionalString(
        params, key: "command", maximumBytes: CodexApprovalWireLimits.commandBytes),
      displayWorkingDirectory: try optionalString(params, key: "cwd"),
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

  private static func decodeFileChange(
    requestID: RequestID,
    params: [String: JSONValue]
  ) throws -> CodexFileChangeApprovalRequest {
    CodexFileChangeApprovalRequest(
      correlation: try correlation(requestID: requestID, params: params, permitsCallback: false),
      grantRoot: try optionalString(params, key: "grantRoot"),
      reason: try optionalString(params, key: "reason")
    )
  }

  private static func decodePermissions(
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

  private static func correlation(
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

  private static func decodeCommandEvidence(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> CodexCommandExecutionEvidence {
    let reference = try itemReference(params: params, item: item)
    let status = try enumValue(
      try requiredString(item, key: "status", maximumBytes: 32),
      field: "item.status",
      as: CodexCommandExecutionStatus.self
    )
    return CodexCommandExecutionEvidence(
      item: reference.item,
      startedAtMilliseconds: reference.startedAt,
      displayCommand: try requiredString(
        item, key: "command", maximumBytes: CodexApprovalWireLimits.commandBytes),
      workingDirectory: try requiredString(item, key: "cwd"),
      displayActions: try commandActions(item["commandActions"], required: true) ?? [],
      status: status
    )
  }

  private static func decodeFileEvidence(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> CodexFileChangeEvidence {
    let reference = try itemReference(params: params, item: item)
    let status = try enumValue(
      try requiredString(item, key: "status", maximumBytes: 32),
      field: "item.status",
      as: CodexFileChangeStatus.self
    )
    let values = try array(item["changes"], field: "item.changes")
    try validateArray(values, field: "item.changes")
    return CodexFileChangeEvidence(
      item: reference.item,
      startedAtMilliseconds: reference.startedAt,
      changes: try values.enumerated().map { index, value in
        try fileUpdate(value, field: "item.changes[\(index)]")
      },
      status: status
    )
  }

  private static func itemReference(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> (item: CodexApprovalItemKey, startedAt: Int64) {
    let startedAt = try requiredInteger(params, key: "startedAtMs")
    guard startedAt >= 0 else { throw CodexApprovalWireError.invalidField("startedAtMs") }
    return (
      CodexApprovalItemKey(
        threadID: try identifier(params, key: "threadId"),
        turnID: try identifier(params, key: "turnId"),
        itemID: try identifier(item, key: "id")
      ),
      startedAt
    )
  }

  private static func fileUpdate(
    _ value: JSONValue,
    field: String
  ) throws -> CodexFileUpdateEvidence {
    let update = try object(value, field: field)
    let path = try requiredString(update, key: "path")
    let diff = try requiredString(
      update, key: "diff", maximumBytes: CodexApprovalWireLimits.diffBytes)
    let kindObject = try object(update["kind"], field: "\(field).kind")
    let discriminator = try requiredString(kindObject, key: "type", maximumBytes: 32)
    let kind: CodexFileChangeKind
    switch discriminator {
    case "add":
      try requireOnlyKeys(kindObject, allowed: ["type"], context: "\(field).kind")
      kind = .add
    case "delete":
      try requireOnlyKeys(kindObject, allowed: ["type"], context: "\(field).kind")
      kind = .delete
    case "update":
      try requireOnlyKeys(kindObject, allowed: ["type", "move_path"], context: "\(field).kind")
      kind = .update(movePath: try optionalString(kindObject, key: "move_path"))
    default:
      throw CodexApprovalWireError.unknownDiscriminator(
        field: "\(field).kind.type", value: discriminator)
    }
    return CodexFileUpdateEvidence(path: path, diff: diff, kind: kind)
  }

  private static func optionalCommandActions(_ value: JSONValue?) throws -> [CodexCommandAction]? {
    try commandActions(value, required: false)
  }

  private static func commandActions(
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

  private static func commandAction(
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

  private static func optionalNetworkContext(
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

  private static func optionalNetworkAmendments(
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

  private static func permissionProfile(_ value: JSONValue?) throws -> CodexRequestPermissionProfile
  {
    let object = try object(value, field: "permissions")
    try requireOnlyKeys(object, allowed: ["fileSystem", "network"], context: "permissions")
    return CodexRequestPermissionProfile(
      fileSystem: try optionalFileSystemPermissions(object["fileSystem"]),
      network: try optionalNetworkPermissions(object["network"])
    )
  }

  private static func optionalFileSystemPermissions(
    _ value: JSONValue?
  ) throws -> CodexAdditionalFileSystemPermissions? {
    guard value != nil, value != .null else { return nil }
    let object = try object(value, field: "permissions.fileSystem")
    try requireOnlyKeys(
      object,
      allowed: ["entries", "globScanMaxDepth", "read", "write"],
      context: "permissions.fileSystem"
    )
    let depth = try optionalUnsignedInteger(object, key: "globScanMaxDepth")
    if let depth, depth < 1 { throw CodexApprovalWireError.invalidField("globScanMaxDepth") }
    return CodexAdditionalFileSystemPermissions(
      entries: try optionalPermissionEntries(object["entries"]),
      globScanMaximumDepth: depth,
      legacyReadPaths: try optionalStringArray(
        object["read"], field: "permissions.fileSystem.read"),
      legacyWritePaths: try optionalStringArray(
        object["write"], field: "permissions.fileSystem.write")
    )
  }

  private static func optionalNetworkPermissions(
    _ value: JSONValue?
  ) throws -> CodexAdditionalNetworkPermissions? {
    guard value != nil, value != .null else { return nil }
    let object = try object(value, field: "permissions.network")
    try requireOnlyKeys(object, allowed: ["enabled"], context: "permissions.network")
    return CodexAdditionalNetworkPermissions(enabled: try optionalBool(object, key: "enabled"))
  }

  private static func optionalPermissionEntries(
    _ value: JSONValue?
  ) throws -> [CodexFileSystemPermissionEntry]? {
    guard value != nil, value != .null else { return nil }
    let values = try array(value, field: "permissions.fileSystem.entries")
    try validateArray(values, field: "permissions.fileSystem.entries")
    return try values.enumerated().map { index, value in
      let field = "permissions.fileSystem.entries[\(index)]"
      let object = try object(value, field: field)
      try requireOnlyKeys(object, allowed: ["access", "path"], context: field)
      let rawAccess = try requiredString(object, key: "access", maximumBytes: 16)
      guard let access = CodexFileSystemAccess(rawValue: rawAccess) else {
        throw CodexApprovalWireError.unknownDiscriminator(
          field: "\(field).access", value: rawAccess)
      }
      return CodexFileSystemPermissionEntry(
        access: access,
        path: try fileSystemPath(object["path"], field: "\(field).path"))
    }
  }

  private static func fileSystemPath(
    _ value: JSONValue?,
    field: String
  ) throws -> CodexFileSystemPath {
    let object = try object(value, field: field)
    let type = try requiredString(object, key: "type", maximumBytes: 32)
    switch type {
    case "path":
      try requireOnlyKeys(object, allowed: ["type", "path"], context: field)
      return .path(try requiredString(object, key: "path"))
    case "glob_pattern":
      try requireOnlyKeys(object, allowed: ["type", "pattern"], context: field)
      return .globPattern(try requiredString(object, key: "pattern"))
    case "special":
      try requireOnlyKeys(object, allowed: ["type", "value"], context: field)
      return .special(try specialFileSystemPath(object["value"], field: "\(field).value"))
    default:
      throw CodexApprovalWireError.unknownDiscriminator(field: "\(field).type", value: type)
    }
  }

  private static func specialFileSystemPath(
    _ value: JSONValue?,
    field: String
  ) throws -> CodexSpecialFileSystemPath {
    let object = try object(value, field: field)
    let kind = try requiredString(object, key: "kind", maximumBytes: 32)
    switch kind {
    case "root":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .root
    case "minimal":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .minimal
    case "project_roots":
      try requireOnlyKeys(object, allowed: ["kind", "subpath"], context: field)
      return .projectRoots(subpath: try optionalString(object, key: "subpath"))
    case "tmpdir":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .temporaryDirectory
    case "slash_tmp":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .slashTemporaryDirectory
    case "unknown":
      try requireOnlyKeys(object, allowed: ["kind", "path", "subpath"], context: field)
      return .unknown(
        path: try requiredString(object, key: "path"),
        subpath: try optionalString(object, key: "subpath"))
    default:
      throw CodexApprovalWireError.unknownDiscriminator(field: "\(field).kind", value: kind)
    }
  }

  private static func validate(requestID: RequestID) throws {
    guard case .string(let value) = requestID else { return }
    try validateString(
      value, field: "requestId", maximumBytes: CodexApprovalWireLimits.identifierBytes)
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField("requestId") }
  }

  private static func identifier(
    _ object: [String: JSONValue],
    key: String
  ) throws -> String {
    let value = try requiredString(
      object, key: key, maximumBytes: CodexApprovalWireLimits.identifierBytes)
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField(key) }
    return value
  }

  private static func optionalIdentifier(
    _ object: [String: JSONValue],
    key: String
  ) throws -> String? {
    guard
      let value = try optionalString(
        object, key: key, maximumBytes: CodexApprovalWireLimits.identifierBytes)
    else { return nil }
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField(key) }
    return value
  }

  private static func requiredString(
    _ object: [String: JSONValue],
    key: String,
    maximumBytes: Int = CodexApprovalWireLimits.stringBytes
  ) throws -> String {
    guard let value = object[key] else { throw CodexApprovalWireError.missingField(key) }
    guard case .string(let string) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    try validateString(string, field: key, maximumBytes: maximumBytes)
    return string
  }

  private static func optionalString(
    _ object: [String: JSONValue],
    key: String,
    maximumBytes: Int = CodexApprovalWireLimits.stringBytes
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    guard case .string(let string) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    try validateString(string, field: key, maximumBytes: maximumBytes)
    return string
  }

  private static func validateString(
    _ value: String,
    field: String,
    maximumBytes: Int
  ) throws {
    guard value.utf8.count <= maximumBytes else {
      throw CodexApprovalWireError.stringTooLarge(field: field, maximumBytes: maximumBytes)
    }
    guard !value.contains("\0") else { throw CodexApprovalWireError.invalidField(field) }
  }

  private static func requiredInteger(
    _ object: [String: JSONValue],
    key: String
  ) throws -> Int64 {
    guard let value = object[key] else { throw CodexApprovalWireError.missingField(key) }
    guard case .integer(let integer) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return integer
  }

  private static func optionalUnsignedInteger(
    _ object: [String: JSONValue],
    key: String
  ) throws -> UInt? {
    guard let value = object[key], value != .null else { return nil }
    guard case .integer(let integer) = value, integer >= 0, let converted = UInt(exactly: integer)
    else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return converted
  }

  private static func optionalBool(
    _ object: [String: JSONValue],
    key: String
  ) throws -> Bool? {
    guard let value = object[key], value != .null else { return nil }
    guard case .bool(let boolean) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return boolean
  }

  private static func optionalStringArray(
    _ value: JSONValue?,
    field: String
  ) throws -> [String]? {
    guard value != nil, value != .null else { return nil }
    let values = try array(value, field: field)
    try validateArray(values, field: field)
    return try values.enumerated().map { index, value in
      guard case .string(let string) = value else {
        throw CodexApprovalWireError.invalidField("\(field)[\(index)]")
      }
      try validateString(
        string,
        field: "\(field)[\(index)]",
        maximumBytes: CodexApprovalWireLimits.stringBytes
      )
      return string
    }
  }

  private static func object(
    _ value: JSONValue?,
    field: String
  ) throws -> [String: JSONValue] {
    guard let value else { throw CodexApprovalWireError.missingField(field) }
    guard case .object(let object) = value else {
      throw CodexApprovalWireError.invalidField(field)
    }
    return object
  }

  private static func array(
    _ value: JSONValue?,
    field: String
  ) throws -> [JSONValue] {
    guard let value else { throw CodexApprovalWireError.missingField(field) }
    guard case .array(let array) = value else {
      throw CodexApprovalWireError.invalidField(field)
    }
    return array
  }

  private static func validateArray(_ values: [JSONValue], field: String) throws {
    guard values.count <= CodexApprovalWireLimits.arrayCount else {
      throw CodexApprovalWireError.arrayTooLarge(
        field: field,
        maximumCount: CodexApprovalWireLimits.arrayCount
      )
    }
  }

  private static func requireOnlyKeys(
    _ object: [String: JSONValue],
    allowed: Set<String>,
    context: String
  ) throws {
    guard let unknown = object.keys.first(where: { !allowed.contains($0) }) else { return }
    throw CodexApprovalWireError.unknownField(context: context, field: unknown)
  }

  private static func enumValue<Value: RawRepresentable>(
    _ rawValue: String,
    field: String,
    as _: Value.Type
  ) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: rawValue) else {
      throw CodexApprovalWireError.unknownDiscriminator(field: field, value: rawValue)
    }
    return value
  }

  private static func validateEvidenceSize(_ value: JSONValue?) throws {
    guard let value else { throw CodexApprovalWireError.missingField("params") }
    let data: Data
    do {
      data = try JSONEncoder().encode(value)
    } catch {
      throw CodexApprovalWireError.invalidField("params")
    }
    guard data.count <= CodexApprovalWireLimits.totalEvidenceBytes else {
      throw CodexApprovalWireError.evidenceTooLarge(
        maximumBytes: CodexApprovalWireLimits.totalEvidenceBytes)
    }
  }

  private static func isNormalizedAbsolutePath(_ value: String) -> Bool {
    guard value.hasPrefix("/"), value == "/" || !value.hasSuffix("/") else { return false }
    if value.contains("//") || value.contains("/./") || value.contains("/../") { return false }
    return !value.hasSuffix("/.") && !value.hasSuffix("/..")
  }
}
