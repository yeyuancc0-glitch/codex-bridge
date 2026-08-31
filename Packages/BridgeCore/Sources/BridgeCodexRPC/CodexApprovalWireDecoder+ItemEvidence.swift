import Foundation

extension CodexApprovalWireDecoder {
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

  public static func decodeSemanticNotification(
    _ notification: RPCNotification
  ) throws -> CodexSemanticExecutionEvidence {
    try validateEvidenceSize(notification.params)
    let params = try object(notification.params, field: "params")
    switch notification.method {
    case "turn/plan/updated":
      return .planChanged(try decodePlanUpdate(params))
    case "item/completed":
      let item = try object(params["item"], field: "item")
      let type = try requiredString(item, key: "type", maximumBytes: 64)
      switch type {
      case "commandExecution":
        return .commandCompleted(try decodeCompletedCommand(params: params, item: item))
      case "fileChange":
        return .fileChangeCompleted(try decodeCompletedFileChange(params: params, item: item))
      default:
        throw CodexApprovalWireError.unsupportedItemType(type)
      }
    default:
      throw CodexApprovalWireError.unsupportedRequestMethod(notification.method)
    }
  }

  static func decodePlanUpdate(
    _ params: [String: JSONValue]
  ) throws -> CodexPlanUpdateEvidence {
    let values = try array(params["plan"], field: "plan")
    guard !values.isEmpty, values.count <= 128 else {
      throw CodexApprovalWireError.arrayTooLarge(field: "plan", maximumCount: 128)
    }
    let steps = try values.enumerated().map { index, value in
      let field = "plan[\(index)]"
      let step = try object(value, field: field)
      try requireOnlyKeys(step, allowed: ["step", "status"], context: field)
      return CodexPlanStepEvidence(
        text: try requiredString(step, key: "step"),
        status: try enumValue(
          try requiredString(step, key: "status", maximumBytes: 32),
          field: "\(field).status",
          as: CodexPlanStepStatus.self
        )
      )
    }
    return CodexPlanUpdateEvidence(
      threadID: try identifier(params, key: "threadId"),
      turnID: try identifier(params, key: "turnId"),
      steps: steps,
      explanation: try optionalString(params, key: "explanation", maximumBytes: 8_192)
    )
  }

  static func decodeCompletedCommand(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> CodexCompletedCommandEvidence {
    let reference = try completedItemReference(params: params, item: item)
    let status = try enumValue(
      try requiredString(item, key: "status", maximumBytes: 32),
      field: "item.status",
      as: CodexCommandExecutionStatus.self
    )
    guard status != .inProgress else { throw CodexApprovalWireError.invalidField("item.status") }
    return CodexCompletedCommandEvidence(
      item: reference.item,
      completedAtMilliseconds: reference.completedAt,
      displayCommand: try requiredString(item, key: "command", maximumBytes: 4_096),
      exitCode: try optionalInt32(item, key: "exitCode"),
      status: status
    )
  }

  static func decodeCompletedFileChange(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> CodexCompletedFileChangeEvidence {
    let reference = try completedItemReference(params: params, item: item)
    let status = try enumValue(
      try requiredString(item, key: "status", maximumBytes: 32),
      field: "item.status",
      as: CodexFileChangeStatus.self
    )
    guard status != .inProgress else { throw CodexApprovalWireError.invalidField("item.status") }
    let values = try array(item["changes"], field: "item.changes")
    try validateArray(values, field: "item.changes")
    return CodexCompletedFileChangeEvidence(
      item: reference.item,
      completedAtMilliseconds: reference.completedAt,
      changes: try values.enumerated().map { index, value in
        try fileUpdate(value, field: "item.changes[\(index)]")
      },
      status: status
    )
  }

  static func completedItemReference(
    params: [String: JSONValue],
    item: [String: JSONValue]
  ) throws -> (item: CodexApprovalItemKey, completedAt: Int64) {
    let completedAt = try requiredInteger(params, key: "completedAtMs")
    guard completedAt >= 0 else {
      throw CodexApprovalWireError.invalidField("completedAtMs")
    }
    return (
      CodexApprovalItemKey(
        threadID: try identifier(params, key: "threadId"),
        turnID: try identifier(params, key: "turnId"),
        itemID: try identifier(item, key: "id")
      ),
      completedAt
    )
  }

  static func decodeCommandEvidence(
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
      workingDirectory: try requiredCWD(item, key: "cwd"),
      displayActions: try commandActions(item["commandActions"], required: true) ?? [],
      status: status
    )
  }

  static func decodeFileEvidence(
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

  static func itemReference(
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

  static func fileUpdate(
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
}
