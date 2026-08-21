import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func parseSubmission(_ arguments: [String: Value]?) throws
    -> MCPServiceTaskSubmission
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 96 * 1_024 else {
      throw MCPError.invalidParams("The task request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "prompt", "thread_id", "execution_model", "execution_effort",
        "skill_name",
        "supervisor_model", "supervisor_effort", "permission_mode", "network_access",
        "acceptance_criteria", "client_request_id",
      ],
      required: ["project_id", "prompt"]
    )
    let prompt = try values.requiredText("prompt", maximumUTF8Bytes: 32 * 1_024)
    let criteria = try values.optionalStringArray(
      "acceptance_criteria",
      maximumCount: 32,
      maximumElementUTF8Bytes: 4_096
    )
    guard ([prompt] + criteria).allSatisfy(OutboundContentSecurity.isSafe) else {
      throw MCPError.invalidParams("Task text contains restricted local data.")
    }
    let permissionMode = try values.optionalIdentifier(
      "permission_mode",
      maximumUTF8Bytes: 32
    )
    if let permissionMode,
      permissionMode != "read-only" && permissionMode != "workspace-write"
    {
      throw MCPError.invalidParams("Argument 'permission_mode' is invalid.")
    }
    let supervisorModel = try values.optionalIdentifier(
      "supervisor_model",
      maximumUTF8Bytes: 256
    )
    let supervisorEffort = try values.optionalIdentifier(
      "supervisor_effort",
      maximumUTF8Bytes: 64
    )
    guard (supervisorModel == nil) == (supervisorEffort == nil) else {
      throw MCPError.invalidParams(
        "Supervisor model and effort must be supplied together."
      )
    }
    return MCPServiceTaskSubmission(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      prompt: prompt,
      skillName: try values.optionalIdentifier("skill_name", maximumUTF8Bytes: 128),
      threadID: try values.optionalIdentifier("thread_id", maximumUTF8Bytes: 1_024),
      executionModel: try values.optionalIdentifier(
        "execution_model",
        maximumUTF8Bytes: 256
      ),
      executionEffort: try values.optionalIdentifier(
        "execution_effort",
        maximumUTF8Bytes: 64
      ),
      supervisorModel: supervisorModel,
      supervisorEffort: supervisorEffort,
      permissionMode: permissionMode,
      networkAccess: try values.optionalBoolean("network_access") ?? false,
      acceptanceCriteria: criteria,
      clientRequestID: try values.optionalIdentifier(
        "client_request_id",
        maximumUTF8Bytes: 512
      )
    )
  }

  func parseDirectWrite(_ arguments: [String: Value]?) throws -> MCPDirectWriteRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The write request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "mode", "content", "expected_sha256", "create_parents",
        "client_request_id",
      ],
      required: ["project_id", "relative_path", "mode", "content"]
    )
    let mode = try values.requiredIdentifier("mode", maximumUTF8Bytes: 16)
    guard mode == "create" || mode == "replace" else {
      throw MCPError.invalidParams("Argument 'mode' is invalid.")
    }
    let content = try values.requiredText("content", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafeSecrets(content) else {
      throw BridgeMCPQueryError.unsafeContentDetected
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    return MCPDirectWriteRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: path,
      mode: mode,
      content: content,
      expectedSHA256: try values.optionalIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      createParents: try values.optionalBoolean("create_parents") ?? false,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseDirectEdit(_ arguments: [String: Value]?) throws -> MCPDirectEditRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The edit request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "expected_sha256", "old_text", "new_text",
        "expected_replacements", "client_request_id",
      ],
      required: ["project_id", "relative_path", "expected_sha256", "old_text", "new_text"]
    )
    let oldText = try values.requiredText("old_text", maximumUTF8Bytes: 256 * 1_024)
    let newText = try values.requiredText("new_text", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafeSecrets(oldText),
      OutboundContentSecurity.isSafeSecrets(newText)
    else {
      throw BridgeMCPQueryError.unsafeContentDetected
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    return MCPDirectEditRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: path,
      expectedSHA256: try values.requiredIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      oldText: oldText,
      newText: newText,
      expectedReplacements: try values.optionalPositiveInteger(
        "expected_replacements", maximum: 1_000) ?? 1,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseDirectPatch(_ arguments: [String: Value]?) throws -> MCPDirectPatchRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The patch request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "patch", "client_request_id"],
      required: ["project_id", "patch"]
    )
    let patch = try values.requiredText("patch", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafeSecrets(patch) else {
      throw MCPError.invalidParams("Patch text contains restricted local data.")
    }
    return MCPDirectPatchRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      patch: patch,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseDirectExec(_ arguments: [String: Value]?) throws -> MCPDirectExecRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The command request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "command_id", "argv", "working_directory", "tty", "yield_time_ms",
        "timeout_ms", "client_request_id",
      ],
      required: ["project_id", "argv"]
    )
    let argv = try values.optionalStringArray(
      "argv", maximumCount: 128, maximumElementUTF8Bytes: 4_096)
    guard !argv.isEmpty else {
      throw MCPError.invalidParams("Argument 'argv' must contain an executable.")
    }
    let commandID = try values.optionalIdentifier("command_id", maximumUTF8Bytes: 256)
    let workingDirectory = try values.optionalIdentifier(
      "working_directory", maximumUTF8Bytes: 1_024)
    if let workingDirectory {
      let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed != "." && !trimmed.hasPrefix("./")
        && !OutboundContentSecurity.isSafeRelativePath(trimmed)
      {
        throw MCPError.invalidParams(
          "Argument 'working_directory' must be a safe relative path.")
      }
    }
    let yieldTimeMS = try values.optionalNonnegativeInteger("yield_time_ms").map(Int.init)
    let timeoutMS = try values.optionalPositiveInteger(
      "timeout_ms", maximum: 3_600_000)
    let tty = try values.optionalBoolean("tty") ?? false
    guard !tty else {
      throw MCPError.invalidParams("Argument 'tty' must be false in this version.")
    }
    return MCPDirectExecRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      commandID: commandID,
      argv: argv,
      workingDirectory: workingDirectory,
      tty: tty,
      yieldTimeMS: yieldTimeMS ?? 1_000,
      timeoutMS: timeoutMS ?? 300_000,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseRunSkillAction(_ arguments: [String: Value]?) throws
    -> MCPRunSkillActionRequest
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The Skill action request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "skill_name", "action_name", "arguments", "project_id",
        "yield_time_ms", "timeout_ms", "client_request_id",
      ],
      required: ["skill_name", "action_name", "project_id"]
    )
    let skillName = try values.requiredIdentifier("skill_name", maximumUTF8Bytes: 128)
    let actionName = try values.requiredIdentifier("action_name", maximumUTF8Bytes: 128)
    let arguments = try values.optionalStringArray(
      "arguments", maximumCount: 128, maximumElementUTF8Bytes: 4_096)
    guard arguments.allSatisfy(OutboundContentSecurity.isSafe) else {
      throw MCPError.invalidParams("Skill arguments contain restricted local data.")
    }
    return MCPRunSkillActionRequest(
      skillName: skillName,
      actionName: actionName,
      arguments: arguments,
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      yieldTimeMS: try values.optionalNonnegativeInteger("yield_time_ms").map(Int.init) ?? 1_000,
      timeoutMS: try values.optionalPositiveInteger("timeout_ms", maximum: 3_600_000) ?? 300_000,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseDirectGitCommit(_ arguments: [String: Value]?) throws
    -> MCPDirectGitCommitRequest
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The git commit request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "message", "files", "client_request_id"],
      required: ["project_id", "message"]
    )
    let files = try values.optionalStringArray(
      "files", maximumCount: 128, maximumElementUTF8Bytes: 1_024)
    for file in files {
      guard OutboundContentSecurity.isSafeRelativePath(file) else {
        throw MCPError.invalidParams("Argument 'files' must contain safe relative paths.")
      }
    }
    return MCPDirectGitCommitRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      message: try values.requiredText("message", maximumUTF8Bytes: 4_096),
      files: files,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func parseDirectManagePath(_ arguments: [String: Value]?) throws
    -> MCPDirectManagePathRequest
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The path request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "action", "relative_path", "expected_sha256",
        "destination_relative_path", "source_expected_sha256", "destination_expected_absent",
        "client_request_id",
      ],
      required: ["project_id", "action", "relative_path"]
    )
    let action = try values.requiredIdentifier("action", maximumUTF8Bytes: 32)
    guard
      ["delete_file", "move_file", "create_directory", "delete_empty_directory"].contains(action)
    else {
      throw MCPError.invalidParams("Argument 'action' is invalid.")
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    let destination = try values.optionalIdentifier(
      "destination_relative_path", maximumUTF8Bytes: 1_024)
    if let destination, !OutboundContentSecurity.isSafeRelativePath(destination) {
      throw MCPError.invalidParams(
        "Argument 'destination_relative_path' must be a safe relative path.")
    }
    if action == "move_file", destination == nil {
      throw MCPError.invalidParams("Argument 'destination_relative_path' is required for move.")
    }
    return MCPDirectManagePathRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      action: action,
      relativePath: path,
      expectedSHA256: try values.optionalIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      destinationRelativePath: destination,
      sourceExpectedSHA256: try values.optionalIdentifier(
        "source_expected_sha256", maximumUTF8Bytes: 64),
      destinationExpectedAbsent: try values.optionalBoolean("destination_expected_absent") ?? true,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

}
