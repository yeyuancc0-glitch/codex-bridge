import BridgeCodexRPC
import BridgeDomain
import Foundation

package enum ExecutionApprovalResponse: Sendable {
  case command
  case fileChange
  case permissions(JSONValue)

  func value(for decision: LocalApprovalDecision) -> JSONValue {
    let allowed = decision == .allow
    switch self {
    case .command, .fileChange:
      return .object(["decision": .string(allowed ? "accept" : "decline")])
    case .permissions(let permissions):
      return .object([
        "permissions": allowed ? permissions : .object([:]),
        "scope": .string("turn"),
        "strictAutoReview": .bool(false),
      ])
    }
  }
}

package struct PreparedExecutionApproval: Sendable {
  let request: ExecutionApprovalRequest
  let response: ExecutionApprovalResponse
}

package enum ExecutionApprovalBuilder {
  static func build(
    approvalID: String,
    taskID: TaskID,
    binding: ExecutionBinding,
    request: CodexApprovalRequest,
    itemEvidence: CodexApprovalItemEvidence,
    rawParameters: JSONValue?,
    projectRoot: String
  ) throws -> PreparedExecutionApproval {
    let correlation = request.correlation.item
    guard correlation.threadID == binding.threadID,
      correlation.turnID == binding.turnID,
      itemEvidence.item == correlation
    else {
      throw ExecutionServiceError.bindingMismatch
    }

    switch request {
    case .command(let command):
      guard case .commandExecution(let evidence) = itemEvidence else {
        throw ExecutionServiceError.protocolViolation("command approval item")
      }
      let displayCommand =
        ExecutionValidation.redacted(
          command.displayCommand ?? evidence.displayCommand,
          maximumBytes: 8 * 1_024
        ) ?? "Command details unavailable"
      let reason = ExecutionValidation.redacted(command.reason, maximumBytes: 4 * 1_024)
      let approval = try ExecutionApprovalRequest(
        id: approvalID,
        taskID: taskID,
        binding: binding,
        itemID: correlation.itemID,
        kind: .command,
        title: "Run command",
        summary: "Codex requests permission to run a command.",
        displayCommand: displayCommand,
        reason: reason
      )
      return PreparedExecutionApproval(request: approval, response: .command)

    case .fileChange(let fileChange):
      guard case .fileChange(let evidence) = itemEvidence else {
        throw ExecutionServiceError.protocolViolation("file approval item")
      }
      var paths: [String] = []
      for change in evidence.changes {
        paths.append(try ExecutionValidation.relativePath(change.path, root: projectRoot))
        if case .update(let movePath) = change.kind, let movePath {
          paths.append(try ExecutionValidation.relativePath(movePath, root: projectRoot))
        }
      }
      paths = Array(Set(paths)).sorted()
      let reason = ExecutionValidation.redacted(fileChange.reason, maximumBytes: 4 * 1_024)
      let approval = try ExecutionApprovalRequest(
        id: approvalID,
        taskID: taskID,
        binding: binding,
        itemID: correlation.itemID,
        kind: .fileChange,
        title: "Apply file changes",
        summary: paths.isEmpty
          ? "Codex requests permission to apply project file changes."
          : "Codex requests permission to change \(paths.count) project file(s).",
        relativePaths: paths,
        reason: reason
      )
      return PreparedExecutionApproval(request: approval, response: .fileChange)

    case .permissions(let permissions):
      guard case .commandExecution = itemEvidence else {
        throw ExecutionServiceError.protocolViolation("permissions approval item")
      }
      let reason = ExecutionValidation.redacted(permissions.reason, maximumBytes: 4 * 1_024)
      let rawPermissions = rawParameters?.objectValue?["permissions"] ?? .object([:])
      let approval = try ExecutionApprovalRequest(
        id: approvalID,
        taskID: taskID,
        binding: binding,
        itemID: correlation.itemID,
        kind: .permissions,
        title: "Grant additional permissions",
        summary: "Codex requests additional file-system or network permissions.",
        reason: reason
      )
      return PreparedExecutionApproval(
        request: approval,
        response: .permissions(rawPermissions)
      )
    }
  }
}
