import BridgeCodexRPC
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
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

package struct ExecutionApprovalLimits: Sendable {
  let projectPolicy: ProjectAccessPolicy
  let taskPermissionMode: ServicePermissionMode
  let taskNetworkAllowed: Bool

  init(request: ExecutionRequest) {
    projectPolicy = request.project.accessPolicy
    taskPermissionMode = request.task.permissionMode
    taskNetworkAllowed = request.task.networkAllowed
  }
}

package enum ExecutionApprovalBuilder {
  static func build(
    approvalID: String,
    taskID: TaskID,
    binding: ExecutionBinding,
    request: CodexApprovalRequest,
    itemEvidence: CodexApprovalItemEvidence,
    rawParameters: JSONValue?,
    projectRoot: String,
    limits: ExecutionApprovalLimits
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
      if command.networkContext != nil
        || command.proposedNetworkPolicyAmendments?.contains(where: { $0.action == .allow }) == true
      {
        try requireNetworkPermission(limits)
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
      try requireWritePermission(limits)
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
      let scope = try permissionScope(
        permissions.permissions,
        projectRoot: projectRoot,
        limits: limits
      )
      let rawPermissions = rawParameters?.objectValue?["permissions"] ?? .object([:])
      let approval = try ExecutionApprovalRequest(
        id: approvalID,
        taskID: taskID,
        binding: binding,
        itemID: correlation.itemID,
        kind: .permissions,
        title: "Grant additional permissions",
        summary: scope.summary,
        displayCommand: scope.details.joined(separator: "\n"),
        relativePaths: scope.relativePaths,
        reason: reason
      )
      return PreparedExecutionApproval(
        request: approval,
        response: .permissions(rawPermissions)
      )
    }
  }

  private struct PermissionScope {
    let summary: String
    let details: [String]
    let relativePaths: [String]
  }

  private static func permissionScope(
    _ permissions: CodexRequestPermissionProfile,
    projectRoot: String,
    limits: ExecutionApprovalLimits
  ) throws -> PermissionScope {
    var details: [String] = []
    var paths: [String] = []
    if let fileSystem = permissions.fileSystem {
      try appendFileSystemScope(
        fileSystem,
        projectRoot: projectRoot,
        limits: limits,
        details: &details,
        paths: &paths
      )
    }
    if permissions.network?.enabled == true {
      try requireNetworkPermission(limits)
      details.append("Network access: enabled for this turn")
    }
    if details.isEmpty { details.append("No additional capabilities") }
    paths = Array(Set(paths)).sorted()
    let summary =
      "Codex requests \(details.count) additional permission scope(s) for this turn."
    return PermissionScope(summary: summary, details: details, relativePaths: paths)
  }

  private static func appendFileSystemScope(
    _ fileSystem: CodexAdditionalFileSystemPermissions,
    projectRoot: String,
    limits: ExecutionApprovalLimits,
    details: inout [String],
    paths: inout [String]
  ) throws {
    for entry in fileSystem.entries ?? [] {
      let path = try permissionPath(entry.path, projectRoot: projectRoot)
      switch entry.access {
      case .write:
        try requireWritePermission(limits)
        details.append("File-system write: \(path.display)")
      case .read:
        guard limits.projectPolicy.read == .allowed else {
          throw ExecutionServiceError.approvalExceedsPolicy
        }
        details.append("File-system read: \(path.display)")
      case .deny:
        details.append("File-system deny: \(path.display)")
      }
      if let relative = path.relative { paths.append(relative) }
    }
    for path in fileSystem.legacyReadPaths ?? [] {
      guard limits.projectPolicy.read == .allowed else {
        throw ExecutionServiceError.approvalExceedsPolicy
      }
      let relative = try ExecutionValidation.relativePath(path, root: projectRoot)
      details.append("File-system read: \(relative)")
      paths.append(relative)
    }
    for path in fileSystem.legacyWritePaths ?? [] {
      try requireWritePermission(limits)
      let relative = try ExecutionValidation.relativePath(path, root: projectRoot)
      details.append("File-system write: \(relative)")
      paths.append(relative)
    }
  }

  private static func requireWritePermission(_ limits: ExecutionApprovalLimits) throws {
    guard limits.taskPermissionMode == .workspaceWrite,
      limits.projectPolicy.write != .denied
    else {
      throw ExecutionServiceError.approvalExceedsPolicy
    }
  }

  private static func requireNetworkPermission(_ limits: ExecutionApprovalLimits) throws {
    guard limits.taskNetworkAllowed, limits.projectPolicy.network != .denied else {
      throw ExecutionServiceError.approvalExceedsPolicy
    }
  }

  private struct PermissionPath {
    let display: String
    let relative: String?
  }

  private static func permissionPath(
    _ path: CodexFileSystemPath,
    projectRoot: String
  ) throws -> PermissionPath {
    switch path {
    case .path(let value):
      let relative = try ExecutionValidation.relativePath(value, root: projectRoot)
      return PermissionPath(display: relative, relative: relative)
    case .globPattern:
      throw ExecutionServiceError.protocolViolation("glob permission path")
    case .special(.projectRoots(let subpath)):
      guard let subpath, !subpath.isEmpty else {
        return PermissionPath(display: "Project root", relative: nil)
      }
      let relative = try ExecutionValidation.relativePath(subpath, root: projectRoot)
      return PermissionPath(display: relative, relative: relative)
    case .special:
      throw ExecutionServiceError.protocolViolation("special permission path")
    }
  }
}
