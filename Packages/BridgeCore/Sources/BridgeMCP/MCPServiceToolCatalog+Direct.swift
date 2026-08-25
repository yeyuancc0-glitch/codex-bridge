import MCP

extension MCPServiceToolCatalog {
  static let executionEnvironmentSchema = objectSchema(
    properties: [
      "bridge_sandbox": stringSchema,
      "scope": stringSchema,
      "sandbox_exec": stringSchema,
      "nested_sandbox": stringSchema,
      "loopback": stringSchema,
      "child_network_policy": stringSchema,
      "xcodebuild_nested_sandbox": stringSchema,
      "loopback_bind": stringSchema,
      "limitations": arraySchema(stringSchema),
    ],
    required: ["bridge_sandbox", "sandbox_exec", "nested_sandbox", "loopback", "limitations"]
  )

  static let directMutationOutputSchema = outputSchema(
    properties: [
      "relative_path": stringSchema,
      "operation": stringSchema,
      "old_sha256": stringSchema,
      "new_sha256": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "bounded_diff": objectSchema(
        properties: [
          "removed_lines": arraySchema(stringSchema),
          "added_lines": arraySchema(stringSchema),
          "truncated": boolSchema,
          "byte_count": integerSchema(minimum: 0),
        ],
        required: ["removed_lines", "added_lines", "truncated", "byte_count"]
      ),
    ],
    required: ["relative_path", "operation", "byte_count", "bounded_diff"]
  )

  static let directMutationReceiptSchema = objectSchema(
    properties: [
      "relative_path": stringSchema,
      "operation": stringSchema,
      "old_sha256": stringSchema,
      "new_sha256": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "bounded_diff": objectSchema(
        properties: [
          "removed_lines": arraySchema(stringSchema),
          "added_lines": arraySchema(stringSchema),
          "truncated": boolSchema,
          "byte_count": integerSchema(minimum: 0),
        ],
        required: ["removed_lines", "added_lines", "truncated", "byte_count"]
      ),
    ],
    required: ["relative_path", "operation", "byte_count", "bounded_diff"]
  )

  static let directManagePathOutputSchema = outputSchema(
    properties: [
      "relative_path": stringSchema,
      "source_relative_path": stringSchema,
      "destination_relative_path": stringSchema,
      "operation": stringSchema,
      "sha256": stringSchema,
      "old_sha256": stringSchema,
      "new_sha256": stringSchema,
      "byte_count": integerSchema(minimum: 0),
    ],
    required: ["relative_path", "source_relative_path", "operation", "byte_count"]
  )

  static let directWriteProjectFile = Tool(
    name: MCPServiceToolName.directWriteProjectFile.rawValue,
    title: "Direct write project file",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks the MCP client "
      + "to edit the local project without delegating the work to Codex. Creates a new file or "
      + "atomically replaces an existing file inside the approved project root.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "relative_path": boundedStringSchema(maximum: 1_024),
        "mode": ["type": "string", "enum": ["create", "replace"]],
        "content": boundedStringSchema(maximum: 256 * 1_024),
        "expected_sha256": nullableStringSchema(maximum: 64),
        "create_parents": boolSchema,
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "relative_path", "mode", "content"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    ),
    outputSchema: directMutationOutputSchema
  )

  static let directEditProjectFile = Tool(
    name: MCPServiceToolName.directEditProjectFile.rawValue,
    title: "Direct edit project file",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks the MCP client "
      + "to edit the local project without delegating the work to Codex. Applies an exact text "
      + "replacement guarded by the file revision read earlier.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "relative_path": boundedStringSchema(maximum: 1_024),
        "expected_sha256": boundedStringSchema(maximum: 64),
        "old_text": boundedStringSchema(maximum: 256 * 1_024),
        "new_text": boundedStringSchema(maximum: 256 * 1_024),
        "expected_replacements": integerSchema(minimum: 1, maximum: 1_000),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "relative_path", "expected_sha256", "old_text", "new_text"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: directMutationOutputSchema
  )

  static let directApplyProjectPatch = Tool(
    name: MCPServiceToolName.directApplyProjectPatch.rawValue,
    title: "Direct apply project patch",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks the MCP client "
      + "to edit the local project without delegating the work to Codex. Applies a multi-file "
      + "exact-line patch. Accepts the Bridge format below or a standard unified diff with "
      + "`--- a/path`, `+++ b/path`, and `@@` hunks. Deletion and rename diffs are rejected. "
      + "Bridge syntax: the `*** Begin Patch` and `*** End Patch` outer lines may both be omitted; "
      + "when used they must appear as a pair. "
      + "each file starts with `*** Update File: relative/path` or `*** Add File: relative/path`. "
      + "For updates, use `@@` (or `@@ -old +new @@`) followed by unchanged lines prefixed with "
      + "one space, removed lines prefixed with `-`, and added lines prefixed with `+`. An update "
      + "must include at least one exact removed or context line. Example: "
      + "`*** Begin Patch\n*** Update File: notes.txt\n@@\n-old\n+new\n*** End Patch`. "
      + "Read the current file first; a non-unique or stale exact context returns invalid_patch.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "patch": boundedStringSchema(maximum: 256 * 1_024),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "patch"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "operations": arraySchema(directMutationReceiptSchema),
        "partial_commit": objectSchema(
          properties: [
            "changed_files": arraySchema(stringSchema),
            "rollback_status": stringSchema,
          ],
          required: ["changed_files", "rollback_status"]
        ),
      ],
      required: ["operations"]
    )
  )

  static let directManageProjectPath = Tool(
    name: MCPServiceToolName.directManageProjectPath.rawValue,
    title: "Direct manage project path",
    description:
      "Explicit Direct Workspace destructive action. Use only when the user explicitly asks "
      + "the MCP client to move or delete files. Deleting and moving require the current file "
      + "revision read earlier.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "action": [
          "type": "string",
          "enum": ["delete_file", "move_file", "create_directory", "delete_empty_directory"],
        ],
        "relative_path": boundedStringSchema(maximum: 1_024),
        "expected_sha256": nullableStringSchema(maximum: 64),
        "destination_relative_path": nullableStringSchema(maximum: 1_024),
        "source_expected_sha256": nullableStringSchema(maximum: 64),
        "destination_expected_absent": boolSchema,
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "action", "relative_path"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: directManagePathOutputSchema
  )

  static let directExecProjectCommand = Tool(
    name: MCPServiceToolName.directExecCommand.rawValue,
    title: "Direct execute project command",
    description:
      "Explicit Direct Workspace action that runs a user-registered project command (or a "
      + "built-in safe command) on the local machine. Use only when the user explicitly asks "
      + "the MCP client to run a command inside the project. The session streams bounded "
      + "output and can be read with direct_read_command. tty must be false in this version.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "command_id": nullableStringSchema(maximum: 256),
        "argv": arraySchema(boundedStringSchema(maximum: 4_096)),
        "working_directory": nullableStringSchema(maximum: 1_024),
        "tty": ["type": "boolean", "const": false],
        "yield_time_ms": integerSchema(minimum: 0, maximum: 60_000),
        "timeout_ms": integerSchema(minimum: 1, maximum: 3_600_000),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "argv"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: directExecOutputSchema
  )

  static let directReadCommand = Tool(
    name: MCPServiceToolName.directReadCommand.rawValue,
    title: "Read direct command",
    description:
      "Read the latest bounded output of a direct command session. Use only when the user "
      + "explicitly asked the MCP client to run commands directly and this session was started with "
      + "direct_exec_project_command. timed_out reports only the command execution deadline; "
      + "read_timeout reports only expiration of this optional read wait.",
    inputSchema: objectSchema(
      properties: [
        "session_id": boundedStringSchema(maximum: 128),
        "wait_timeout_ms": integerSchema(minimum: 0, maximum: 10_000),
      ],
      required: ["session_id"]
    ),
    annotations: readAnnotations,
    outputSchema: directCommandOutputSchema
  )

  static let directWriteStdin = Tool(
    name: MCPServiceToolName.directWriteStdin.rawValue,
    title: "Write direct command stdin",
    description:
      "Write a bounded chunk of input to the stdin of a running interactive direct command "
      + "session. Use only when the user explicitly asked the MCP client to drive an interactive "
      + "command directly. Set close_stdin=true after the final chunk to deliver EOF; this lets "
      + "buffered programs such as grep flush output and exit before direct_read_command is polled.",
    inputSchema: objectSchema(
      properties: [
        "session_id": boundedStringSchema(maximum: 128),
        "data": boundedStringSchema(maximum: 64 * 1_024),
        "close_stdin": boolSchema,
      ],
      required: ["session_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "bytes_written": integerSchema(minimum: 0, maximum: 64 * 1_024),
        "stdin_closed": boolSchema,
      ],
      required: ["bytes_written", "stdin_closed"]
    )
  )

  static let directInterruptCommand = Tool(
    name: MCPServiceToolName.directInterruptCommand.rawValue,
    title: "Interrupt direct command",
    description:
      "Cancel a running direct command session, terminating its process group. Use only when "
      + "the user explicitly asked the MCP client to run commands directly and the session must stop.",
    inputSchema: objectSchema(
      properties: ["session_id": boundedStringSchema(maximum: 128)],
      required: ["session_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: directCommandOutputSchema
  )

  static let directCommandPayloadSchema = objectSchema(
    properties: [
      "session_id": stringSchema,
      "status": stringSchema,
      "exit_code": integerSchema(minimum: Int(Int32.min), maximum: Int(Int32.max)),
      "timed_out": boolSchema,
      "command_status": stringSchema,
      "command_timed_out": boolSchema,
      "read_timeout": boolSchema,
      "head": stringSchema,
      "tail": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "truncated": boolSchema,
      "execution_environment": executionEnvironmentSchema,
    ],
    required: ["session_id", "status", "timed_out", "head", "tail", "byte_count", "truncated"]
  )

  static let directCommandOutputSchema = outputSchema(
    properties: [
      "session_id": stringSchema,
      "status": stringSchema,
      "exit_code": integerSchema(minimum: Int(Int32.min), maximum: Int(Int32.max)),
      "timed_out": boolSchema,
      "command_status": stringSchema,
      "command_timed_out": boolSchema,
      "read_timeout": boolSchema,
      "head": stringSchema,
      "tail": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "truncated": boolSchema,
      "execution_environment": executionEnvironmentSchema,
    ],
    required: ["session_id", "status", "timed_out", "head", "tail", "byte_count", "truncated"]
  )

  static let directExecOutputSchema = outputSchema(
    properties: [
      "session_id": stringSchema,
      "status": stringSchema,
      "exit_code": integerSchema(minimum: Int(Int32.min), maximum: Int(Int32.max)),
      "started_at": stringSchema,
      "output": directCommandPayloadSchema,
    ],
    required: ["session_id", "status"]
  )

  static let directGitCommit = Tool(
    name: MCPServiceToolName.directGitCommit.rawValue,
    title: "Direct git commit",
    description:
      "Explicit Direct Workspace action that creates a local Git commit inside the project. "
      + "Use only when the user explicitly asks the MCP client to commit the changes. It stages "
      + "the listed project files (or all changed files when empty) and runs `git commit` with "
      + "the provided message. History-rewriting operations (amend/reset/rebasing) and push are "
      + "never performed.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "message": boundedStringSchema(maximum: 4_096),
        "files": arraySchema(boundedStringSchema(maximum: 1_024)),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "message"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "commit_hash": nullableStringSchema(maximum: 64),
        "changed_files": arraySchema(boundedStringSchema(maximum: 1_024)),
        "summary": stringSchema,
        "exit_code": integerSchema(minimum: 0),
        "index_synchronized": boolSchema,
        "index_synchronization_error": nullableStringSchema(maximum: 4_096),
      ],
      required: ["changed_files", "summary", "exit_code", "index_synchronized"],
      successSchemaVersion: 2
    )
  )
}
