import Foundation

extension BridgeMCPQueryError {
  var toolError: MCPToolErrorDTO {
    switch self {
    case .projectNotFound:
      return error(
        "project_not_found", .callerError, false, "list_projects",
        "The project is unavailable. Use the opaque project_id returned by list_projects."
      )
    case .threadNotFound:
      return error(
        "thread_not_found", .callerError, false, "list_threads",
        "The Thread is unavailable for this project."
      )
    case .pathDenied:
      return error(
        "path_denied", .policyDenied, false, "choose_allowed_project_relative_path",
        "The path is not allowed by the project policy."
      )
    case .pathForbidden:
      return error(
        "path_forbidden", .policyDenied, false, "choose_allowed_project_relative_path",
        "The path is forbidden by the project policy."
      )
    case .pathNotFound:
      return error(
        "path_not_found", .callerError, false, "check_relative_path",
        "The path does not exist."
      )
    case .taskNotFound:
      return error(
        "task_not_found", .callerError, false, "check_task_id",
        "The task is unavailable. A task is not submitted unless submit_task returned a task_id."
      )
    case .idempotencyConflict:
      return error(
        "idempotency_conflict", .stateConflict, false, "use_new_client_request_id",
        "The request identifier is already bound to another task contract."
      )
    case .turnMismatch:
      return error(
        "turn_mismatch", .stateConflict, true, "get_task_and_retry",
        "The active provider run changed. Read the task before retrying."
      )
    case .eventSequenceMismatch:
      return error(
        "task_changed", .stateConflict, true, "get_task_and_retry",
        "The task changed before this operation could be applied."
      )
    case .invalidTaskState:
      return error(
        "invalid_task_state", .stateConflict, false, "get_task",
        "The operation is invalid for the current task state."
      )
    case .contractRejected:
      return error(
        "contract_rejected", .policyDenied, false, "adjust_request_to_project_policy",
        "Local policy rejected the request contract."
      )
    case .busy:
      return error(
        "busy", .infrastructureFailure, true, "wait_and_retry",
        "The Bridge is at its current request limit."
      )
    case .projectBusy(let detail):
      return MCPToolErrorDTO(
        code: "project_busy",
        category: .stateConflict,
        message: Self.projectBusyMessage(detail),
        retryable: true,
        nextAction: "wait_for_workspace_and_retry",
        owner: detail.owner,
        taskID: detail.taskID,
        operationID: detail.operationID,
        sessionID: detail.sessionID
      )
    case .timeout:
      return error(
        "timeout", .infrastructureFailure, true, "retry",
        "The local operation did not finish before its deadline."
      )
    case .unavailable:
      return error(
        "unavailable", .infrastructureFailure, true, "retry_or_check_bridge_status",
        "A required local Bridge component is unavailable."
      )
    case .internalFailure(let correlationID):
      return error(
        "internal_error", .infrastructureFailure, true, "retry_or_contact_local_user",
        "The tool request failed unexpectedly. Quote correlation \(correlationID) when asking the local user to inspect service logs."
      )
    case .fileRevisionConflict:
      return error(
        "file_revision_conflict", .stateConflict, true, "read_file_and_retry",
        "The file content does not match the expected revision."
      )
    case .revisionConflict(let detail):
      return MCPToolErrorDTO(
        code: "revision_conflict",
        category: .stateConflict,
        message: "The file changed since the expected revision.",
        retryable: true,
        nextAction: "read_file_and_retry",
        data: detail.errorData
      )
    case .pathChanged:
      return error(
        "path_changed", .stateConflict, true, "read_path_and_retry",
        "The target changed after it was validated."
      )
    case .writeNotAllowed:
      return error(
        "write_not_allowed", .policyDenied, false, "request_project_write_access",
        "The project does not allow remote writes."
      )
    case .approvalRequired(let approvalID):
      return MCPToolErrorDTO(
        code: "approval_required",
        category: .approvalRequired,
        message: "The local user must approve this action.",
        retryable: true,
        nextAction: "wait_for_local_approval",
        operationID: approvalID
      )
    case .approvalExpired:
      return error(
        "approval_expired", .approvalRequired, true, "request_new_approval",
        "The local approval expired."
      )
    case .approvalDenied:
      return error(
        "approval_denied", .policyDenied, true, "wait_before_requesting_new_approval",
        "The local user denied this action."
      )
    case .invalidPatch, .invalidPatchSyntax:
      return error(
        "invalid_patch_syntax", .callerError, false, "fix_patch_syntax",
        "The patch syntax is invalid. Use the published Bridge patch grammar or a standard ---/+++ unified diff."
      )
    case .patchContextNotFound:
      return error(
        "patch_context_not_found", .stateConflict, true,
        "read_file_and_retry_smaller_patch",
        "The exact patch context was not found in the current file."
      )
    case .patchContextNonUnique:
      return error(
        "patch_context_non_unique", .stateConflict, true,
        "read_file_and_retry_smaller_patch",
        "The exact patch context matched more than one location."
      )
    case .patchContextStale:
      return error(
        "patch_context_stale", .stateConflict, true,
        "read_file_and_retry_smaller_patch",
        "The file revision changed after the patch was prepared."
      )
    case .notGitRepository:
      return error(
        "not_git_repository", .capabilityUnavailable, false, "use_non_git_workflow",
        "The project is not a Git repository."
      )
    case .commandSessionNotFound:
      return error(
        "command_session_not_found", .callerError, false,
        "use_session_id_from_direct_command_receipt",
        "The command session is unavailable."
      )
    case .commandSessionNotRunning:
      return error(
        "command_session_not_running", .stateConflict, false, "read_command_result",
        "The command session exists but is no longer running."
      )
    case .commandTimeout:
      return error(
        "command_timeout", .infrastructureFailure, true, "retry_with_longer_timeout",
        "The command exceeded its time limit."
      )
    case .commandDenied(let reason):
      if let structuredReason = MCPCommandDenialReason(rawValue: reason) {
        return commandError(structuredReason)
      }
      return error(
        "command_denied", .policyDenied, false, "list_project_commands",
        "The requested command was denied: \(reason)"
      )
    case .processLaunchFailed:
      return error(
        "process_launch_failed", .capabilityUnavailable, true, "list_project_commands",
        "The command could not be launched from the approved Direct environment."
      )
    case .gitOperationFailed(let summary):
      return error(
        "git_operation_failed", .infrastructureFailure, true, "inspect_git_result_and_retry",
        "The Git operation failed: \(summary)"
      )
    case .outputLimitExceeded:
      return error(
        "output_limit_exceeded", .capabilityUnavailable, false, "request_smaller_output",
        "The command output exceeded the bounded limit."
      )
    case .durabilityUncertain:
      return error(
        "durability_uncertain", .stateConflict, false, "read_path_before_retry",
        "The mutation was applied, but crash durability was not confirmed."
      )
    case .skillNotFound:
      return error(
        "skill_not_found", .callerError, false, "list_skills",
        "The Skill is unavailable."
      )
    case .skillActionNotFound:
      return error(
        "skill_action_not_found", .callerError, false, "read_skill",
        "The requested Skill action does not exist."
      )
    case .skillActionNotRunnable:
      return error(
        "skill_action_not_runnable", .capabilityUnavailable, false,
        "choose_runnable_skill_action",
        "The requested Skill action cannot be launched."
      )
    case .networkIsolationUnavailable:
      return error(
        "network_isolation_unavailable", .capabilityUnavailable, false,
        "do_not_run_network_skill_action",
        "Network isolation could not be applied for this Skill action."
      )
    case .unsafeContentDetected:
      return error(
        "unsafe_content_detected", .policyDenied, false, "remove_restricted_content",
        "The content contains restricted credential material."
      )
    case .binaryContentUnsupported:
      return error(
        "binary_content_unsupported", .capabilityUnavailable, false, "use_utf8_text_file",
        "Direct file mutation supports UTF-8 text files only."
      )
    case .patchPartialCommit(let partialCommit):
      return MCPToolErrorDTO(
        code: "patch_partial_commit",
        category: .stateConflict,
        message:
          "The multi-file patch did not complete. Inspect the reported paths before any retry.",
        retryable: false,
        nextAction: "inspect_changed_files_before_retry",
        data: [
          "changed_files": partialCommit.changedFiles.joined(separator: "\n"),
          "rollback_status": partialCommit.rollbackStatus,
        ]
      )
    }
  }

  private func commandError(_ reason: MCPCommandDenialReason) -> MCPToolErrorDTO {
    let category: MCPToolErrorCategory
    let nextAction: String
    let message: String
    switch reason {
    case .commandNotRegistered:
      category = .policyDenied
      nextAction = "list_project_commands"
      message = "The command is not registered or available in this project's Direct policy."
    case .invalidArguments:
      category = .callerError
      nextAction = "fix_command_arguments"
      message = "The command arguments do not match the registered command contract."
    case .commandModeDenied:
      category = .policyDenied
      nextAction = "do_not_run_direct_commands"
      message = "Direct command execution is disabled for this project."
    case .networkDenied:
      category = .policyDenied
      nextAction = "use_command_without_network"
      message = "The project policy denies the command's network requirement."
    case .writeDenied:
      category = .policyDenied
      nextAction = "request_project_write_access"
      message = "The project policy denies Direct command execution without write access."
    case .blacklisted:
      category = .policyDenied
      nextAction = "do_not_retry_command"
      message = "The command is blacklisted by the project policy."
    }
    return error(reason.rawValue, category, false, nextAction, message)
  }

  private func error(
    _ code: String,
    _ category: MCPToolErrorCategory,
    _ retryable: Bool,
    _ nextAction: String,
    _ message: String
  ) -> MCPToolErrorDTO {
    MCPToolErrorDTO(
      code: code,
      category: category,
      message: message,
      retryable: retryable,
      nextAction: nextAction
    )
  }

  private static func projectBusyMessage(_ detail: WorkspaceBusyDetail) -> String {
    switch detail.owner {
    case "codex_task":
      return detail.taskID.map { "The project workspace is busy with a Codex task (\($0))." }
        ?? "The project workspace is being acquired by a Codex task."
    case "direct_file":
      return "The project workspace is busy with a Direct file operation."
    case "direct_command":
      return "The project workspace is busy with a running Direct command session."
    default:
      return "The project workspace is busy."
    }
  }
}
