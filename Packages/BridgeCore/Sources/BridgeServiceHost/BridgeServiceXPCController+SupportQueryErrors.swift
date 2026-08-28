import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceXPCController {
  static func mapMCPQueryError(_ error: BridgeMCPQueryError) -> BridgeServiceIPCError {
    switch error {
    case .projectNotFound:
      return .init(code: "project_not_found", message: "The project is unavailable.")
    case .skillNotFound:
      return .init(code: "skill_not_found", message: "The Skill is unavailable.")
    case .skillActionNotFound:
      return .init(
        code: "skill_action_not_found", message: "The requested Skill action does not exist.")
    case .skillActionNotRunnable:
      return .init(
        code: "skill_action_not_runnable",
        message: "The requested Skill action cannot be launched."
      )
    case .threadNotFound:
      return .init(code: "thread_not_found", message: "The Thread is unavailable.")
    case .taskNotFound:
      return .init(code: "task_not_found", message: "The task is unavailable.")
    case .pathDenied:
      return .init(code: "path_denied", message: "The path is not allowed.")
    case .pathNotFound:
      return .init(code: "path_not_found", message: "The path does not exist.")
    case .turnMismatch:
      return .init(code: "turn_mismatch", message: "The active Turn changed.")
    case .busy:
      return .init(code: "busy", message: "The service is busy.", retryable: true)
    case .timeout:
      return .init(code: "timeout", message: "The operation timed out.", retryable: true)
    case .unavailable:
      return .init(
        code: "unavailable",
        message: "A local component is unavailable.",
        retryable: true
      )
    case .internalFailure(let correlationID):
      return .init(
        code: "internal_error",
        message: "The operation failed unexpectedly (correlation \(correlationID)).",
        retryable: true
      )
    case .idempotencyConflict, .eventSequenceMismatch, .invalidTaskState, .contractRejected:
      return .init(
        code: "invalid_state",
        message: "The operation was rejected by local policy."
      )
    case .projectBusy(let detail):
      return .init(
        code: "project_busy",
        message: "The project workspace is busy.",
        retryable: true,
        owner: detail.owner,
        taskID: detail.taskID,
        operationID: detail.operationID,
        sessionID: detail.sessionID
      )
    case .fileRevisionConflict:
      return .init(
        code: "file_revision_conflict",
        message: "The file content does not match the expected revision.",
        retryable: true
      )
    case .revisionConflict:
      return .init(
        code: "revision_conflict",
        message: "The file changed since the expected revision.",
        retryable: true
      )
    case .pathForbidden:
      return .init(code: "path_forbidden", message: "The path is not allowed.")
    case .pathChanged:
      return .init(
        code: "path_changed",
        message: "The target changed after it was validated.",
        retryable: true
      )
    case .writeNotAllowed:
      return .init(
        code: "write_not_allowed", message: "The project does not allow remote writes.")
    case .approvalRequired(let approvalID):
      return .init(
        code: "approval_required",
        message: "The local user must approve this action.",
        retryable: true,
        operationID: approvalID
      )
    case .approvalExpired:
      return .init(
        code: "approval_expired",
        message: "The local approval expired.",
        retryable: true
      )
    case .approvalDenied:
      return .init(
        code: "approval_denied",
        message: "The local user denied this action.",
        retryable: true
      )
    case .invalidPatch, .invalidPatchSyntax:
      return .init(
        code: "invalid_patch_syntax",
        message: "The patch syntax is invalid."
      )
    case .patchContextNotFound:
      return .init(
        code: "patch_context_not_found",
        message: "The exact patch context was not found.",
        retryable: true
      )
    case .patchContextNonUnique:
      return .init(
        code: "patch_context_non_unique",
        message: "The exact patch context matched more than one location.",
        retryable: true
      )
    case .patchContextStale:
      return .init(
        code: "patch_context_stale",
        message: "The file revision changed after the patch was prepared.",
        retryable: true
      )
    case .notGitRepository:
      return .init(code: "not_git_repository", message: "The project is not a Git repository.")
    case .commandSessionNotFound:
      return .init(
        code: "command_session_not_found",
        message: "The command session is unavailable."
      )
    case .commandSessionNotRunning:
      return .init(
        code: "command_session_not_running",
        message: "The command session exists but is no longer running."
      )
    case .commandTimeout:
      return .init(
        code: "command_timeout",
        message: "The command exceeded its time limit.",
        retryable: true
      )
    case .commandDenied(let reason):
      if let structuredReason = MCPCommandDenialReason(rawValue: reason) {
        return .init(
          code: structuredReason.rawValue,
          message: "The requested command was denied by the project policy."
        )
      }
      return .init(
        code: "command_denied",
        message: "The requested command was denied: \(reason)"
      )
    case .processLaunchFailed:
      return .init(
        code: "process_launch_failed",
        message: "The command could not be launched.",
        retryable: true
      )
    case .gitOperationFailed(let summary):
      return .init(
        code: "git_operation_failed",
        message: "The git operation failed: \(summary)",
        retryable: true
      )
    case .outputLimitExceeded:
      return .init(
        code: "output_limit_exceeded",
        message: "The command output exceeded the bounded limit."
      )
    case .durabilityUncertain:
      return .init(
        code: "durability_uncertain",
        message:
          "The mutation was applied, but crash durability was not confirmed. Read the path before retrying."
      )
    case .networkIsolationUnavailable:
      return .init(
        code: "network_isolation_unavailable",
        message: "Network isolation could not be applied for this Skill action."
      )
    case .unsafeContentDetected:
      return .init(
        code: "unsafe_content_detected",
        message: "The content contains restricted credential material."
      )
    case .binaryContentUnsupported:
      return .init(
        code: "binary_content_unsupported",
        message: "Direct file mutation supports UTF-8 text files only."
      )
    case .patchPartialCommit(let partialCommit):
      return .init(
        code: "patch_partial_commit",
        message:
          "The multi-file patch did not complete (rollback: \(partialCommit.rollbackStatus))."
      )
    }
  }
}
