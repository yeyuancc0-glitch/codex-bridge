import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func encodeQueryError(_ error: BridgeMCPQueryError) throws -> CallTool.Result {
    let dto: MCPToolErrorDTO
    switch error {
    case .projectNotFound:
      dto = .init(
        code: "project_not_found",
        message: "The project is unavailable.",
        retryable: false
      )
    case .threadNotFound:
      dto = .init(
        code: "thread_not_found",
        message: "The Thread is unavailable.",
        retryable: false
      )
    case .pathDenied:
      dto = .init(code: "path_denied", message: "The path is not allowed.", retryable: false)
    case .pathNotFound:
      dto = .init(code: "path_not_found", message: "The path does not exist.", retryable: false)
    case .taskNotFound:
      dto = .init(code: "task_not_found", message: "The task is unavailable.", retryable: false)
    case .idempotencyConflict:
      dto = .init(
        code: "idempotency_conflict",
        message: "The request identifier is already bound to another task.",
        retryable: false
      )
    case .turnMismatch:
      dto = .init(code: "turn_mismatch", message: "The active Turn changed.", retryable: false)
    case .eventSequenceMismatch:
      dto = .init(code: "task_changed", message: "The task changed.", retryable: false)
    case .invalidTaskState:
      dto = .init(
        code: "invalid_task_state",
        message: "The operation is invalid for the current task state.",
        retryable: false
      )
    case .contractRejected:
      dto = .init(
        code: "contract_rejected",
        message: "Local policy rejected the task.",
        retryable: false
      )
    case .busy:
      dto = .init(code: "busy", message: "The Bridge is busy.", retryable: true)
    case .projectBusy(let detail):
      dto = .init(
        code: "project_busy",
        message: Self.projectBusyMessage(detail),
        retryable: true,
        owner: detail.owner,
        taskID: detail.taskID,
        operationID: detail.operationID,
        sessionID: detail.sessionID
      )
    case .timeout:
      dto = .init(code: "timeout", message: "The operation timed out.", retryable: true)
    case .unavailable:
      dto = .init(
        code: "unavailable",
        message: "A local component is unavailable.",
        retryable: true
      )
    case .fileRevisionConflict:
      dto = .init(
        code: "file_revision_conflict",
        message: "The file content does not match the expected revision. Read the file again.",
        retryable: true
      )
    case .revisionConflict(let detail):
      dto = .init(
        code: "revision_conflict",
        message: "The file changed since the expected revision. Re-read the file and retry.",
        retryable: true,
        data: detail.errorData
      )
    case .pathForbidden:
      dto = .init(code: "path_forbidden", message: "The path is not allowed.", retryable: false)
    case .pathChanged:
      dto = .init(
        code: "path_changed",
        message: "The target changed after it was validated. Read the file again.",
        retryable: true
      )
    case .writeNotAllowed:
      dto = .init(
        code: "write_not_allowed",
        message: "The project does not allow remote writes.",
        retryable: false
      )
    case .approvalRequired(let approvalID):
      dto = .init(
        code: "approval_required",
        message: "The local user must approve this action (approval \(approvalID)).",
        retryable: true,
        operationID: approvalID
      )
    case .approvalExpired:
      dto = .init(
        code: "approval_expired",
        message: "The local approval expired. Request a new approval.",
        retryable: true
      )
    case .approvalDenied:
      dto = .init(
        code: "approval_denied",
        message: "The local user denied this action. Retry after the denial cooldown expires.",
        retryable: true
      )
    case .invalidPatch:
      dto = .init(
        code: "invalid_patch",
        message:
          "Patch syntax or exact context did not match. Use paired optional Begin/End markers with "
          + "*** Update File and space/-/+ lines, *** Add File and + lines, or a standard ---/+++ "
          + "unified diff. Read the current file before retrying.",
        retryable: false
      )
    case .notGitRepository:
      dto = .init(
        code: "not_git_repository",
        message: "The project is not a Git repository.",
        retryable: false
      )
    case .commandSessionNotFound:
      dto = .init(
        code: "command_session_not_found",
        message: "The command session is unavailable.",
        retryable: false
      )
    case .commandSessionNotRunning:
      dto = .init(
        code: "command_session_not_running",
        message: "The command session exists but is no longer running.",
        retryable: false
      )
    case .commandTimeout:
      dto = .init(
        code: "command_timeout",
        message: "The command exceeded its time limit.",
        retryable: true
      )
    case .commandDenied(let reason):
      dto = .init(
        code: "command_denied",
        message: "The requested command was denied: \(reason)",
        retryable: false
      )
    case .processLaunchFailed:
      dto = .init(
        code: "process_launch_failed",
        message:
          "The command could not be launched. Check the executable path and that it is executable.",
        retryable: true
      )

    case .gitOperationFailed(let summary):
      dto = .init(
        code: "git_operation_failed",
        message: "The git operation failed: \(summary)",
        retryable: true
      )
    case .outputLimitExceeded:
      dto = .init(
        code: "output_limit_exceeded",
        message: "The command output exceeded the bounded limit.",
        retryable: false
      )
    case .durabilityUncertain:
      dto = .init(
        code: "durability_uncertain",
        message:
          "The mutation was applied, but crash durability was not confirmed. Read the path before retrying.",
        retryable: false
      )
    case .skillNotFound:
      dto = .init(code: "skill_not_found", message: "The Skill is unavailable.", retryable: false)
    case .skillActionNotFound:
      dto = .init(
        code: "skill_action_not_found",
        message: "The requested Skill action does not exist.",
        retryable: false
      )
    case .skillActionNotRunnable:
      dto = .init(
        code: "skill_action_not_runnable",
        message: "The requested Skill action cannot be launched.",
        retryable: false
      )
    case .networkIsolationUnavailable:
      dto = .init(
        code: "network_isolation_unavailable",
        message: "Network isolation could not be applied for this Skill action.",
        retryable: false
      )
    case .unsafeContentDetected:
      dto = .init(
        code: "unsafe_content_detected",
        message: "The content contains restricted credential material.",
        retryable: false
      )
    }
    return try resultEncoder.encode(MCPToolErrorOutput(error: dto), isError: true)
  }

  func encodeResultError(_ error: MCPToolResultEncodingError) throws -> CallTool.Result {
    switch error {
    case .resultTooLarge:
      return try resultEncoder.encode(
        MCPToolErrorOutput(
          error: .init(
            code: "result_too_large",
            message: "The result is too large. Request a smaller page.",
            retryable: true
          )
        ),
        isError: true
      )
    }
  }

  static func projectBusyMessage(_ detail: WorkspaceBusyDetail) -> String {
    switch detail.owner {
    case "codex_task":
      if let taskID = detail.taskID {
        return "The project workspace is busy with a Codex task (\(taskID))."
      }
      return "The project workspace is being acquired by a Codex task."
    case "direct_file":
      return "The project workspace is busy with a direct file operation."
    case "direct_command":
      return "The project workspace is busy with a running command session."
    default:
      return "The project workspace is busy."
    }
  }
}
