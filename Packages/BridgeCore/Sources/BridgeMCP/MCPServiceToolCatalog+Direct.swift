import MCP

extension MCPServiceToolCatalog {
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
      + "patch (*** Begin Patch / *** Add File / *** Update File) with per-file revision checks.",
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
      + "output and can be read with direct_read_command.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "command_id": nullableStringSchema(maximum: 256),
        "argv": arraySchema(boundedStringSchema(maximum: 4_096)),
        "working_directory": nullableStringSchema(maximum: 1_024),
        "tty": boolSchema,
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
      + "direct_exec_project_command.",
    inputSchema: objectSchema(
      properties: ["session_id": boundedStringSchema(maximum: 128)],
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
      + "command directly.",
    inputSchema: objectSchema(
      properties: [
        "session_id": boundedStringSchema(maximum: 128),
        "data": boundedStringSchema(maximum: 64 * 1_024),
      ],
      required: ["session_id", "data"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: outputSchema(properties: [:], required: [])
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
      "head": stringSchema,
      "tail": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "truncated": boolSchema,
    ],
    required: ["session_id", "status", "timed_out", "head", "tail", "byte_count", "truncated"]
  )

  static let directCommandOutputSchema = outputSchema(
    properties: [
      "session_id": stringSchema,
      "status": stringSchema,
      "exit_code": integerSchema(minimum: Int(Int32.min), maximum: Int(Int32.max)),
      "timed_out": boolSchema,
      "head": stringSchema,
      "tail": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "truncated": boolSchema,
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
