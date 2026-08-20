import MCP

public enum MCPServiceToolName: String, CaseIterable, Sendable {
  case bridgeStatus = "bridge_status"
  case listProjects = "list_projects"
  case getProject = "get_project"
  case searchProjectFiles = "search_project_files"
  case readProjectFile = "read_project_file"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listModels = "list_models"
  case listSkills = "list_skills"
  case readSkill = "read_skill"
  case runSkillAction = "run_skill_action"
  case getTask = "get_task"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
  case getProjectChanges = "get_project_changes"
  case listProjectCommands = "list_project_commands"
  case directWriteProjectFile = "direct_write_project_file"
  case directEditProjectFile = "direct_edit_project_file"
  case directApplyProjectPatch = "direct_apply_project_patch"
  case directManageProjectPath = "direct_manage_project_path"
  case directExecCommand = "direct_exec_project_command"
  case directReadCommand = "direct_read_command"
  case directWriteStdin = "direct_write_stdin"
  case directInterruptCommand = "direct_interrupt_command"
  case directGitCommit = "direct_git_commit"
}

public struct MCPServiceToolCatalog: Sendable {
  public let definitions: [Tool]

  public init(exposureMode: MCPServiceExposureMode) {
    var tools = [
      Self.bridgeStatus,
      Self.listProjects,
      Self.getProject,
      Self.searchProjectFiles,
      Self.readProjectFile,
      Self.listThreads,
      Self.readThread,
      Self.listModels,
      Self.listSkills,
      Self.readSkill,
      Self.getTask,
      Self.getProjectChanges,
      Self.listProjectCommands,
    ]
    if exposureMode == .full {
      tools.append(
        contentsOf: [
          Self.submitTask,
          Self.runSkillAction,
          Self.steerTask,
          Self.interruptTask,
          Self.directWriteProjectFile,
          Self.directEditProjectFile,
          Self.directApplyProjectPatch,
          Self.directManageProjectPath,
          Self.directExecProjectCommand,
          Self.directReadCommand,
          Self.directWriteStdin,
          Self.directInterruptCommand,
          Self.directGitCommit,
        ]
      )
    }
    definitions = tools
  }

  private static let readAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let bridgeStatus = Tool(
    name: MCPServiceToolName.bridgeStatus.rawValue,
    title: "Bridge status",
    description: "Read the lightweight Codex Bridge service state.",
    inputSchema: objectSchema(properties: [:]),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "app_version": stringSchema,
        "mcp_state": stringSchema,
        "tunnel_state": stringSchema,
        "execution_state": stringSchema,
        "supervisor_state": stringSchema,
        "degradations": arraySchema(stringSchema),
        "pending_approval_count": integerSchema(minimum: 0),
      ],
      required: [
        "app_version", "mcp_state", "tunnel_state", "execution_state", "supervisor_state",
        "degradations", "pending_approval_count",
      ]
    )
  )

  private static let listProjects = Tool(
    name: MCPServiceToolName.listProjects.rawValue,
    title: "List projects",
    description: "List user-approved projects visible to ChatGPT.",
    inputSchema: objectSchema(
      properties: [
        "cursor": nullableStringSchema(maximum: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 100),
      ]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "projects": arraySchema(projectSummarySchema),
        "next_cursor": stringSchema,
      ],
      required: ["projects"]
    )
  )

  private static let getProject = Tool(
    name: MCPServiceToolName.getProject.rawValue,
    title: "Get project",
    description: "Read bounded capabilities for one approved project.",
    inputSchema: projectIDInput,
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["project": projectDetailSchema],
      required: ["project"]
    )
  )

  private static let searchProjectFiles = Tool(
    name: MCPServiceToolName.searchProjectFiles.rawValue,
    title: "Search project files",
    description: "Search bounded text inside one approved project.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "query": boundedStringSchema(maximum: 512),
        "relative_directory": nullableStringSchema(maximum: 1_024),
        "case_sensitive": boolSchema,
        "cursor": nullableStringSchema(maximum: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 50),
      ],
      required: ["project_id", "query"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "matches": arraySchema(searchMatchSchema),
        "next_cursor": stringSchema,
        "skipped_file_count": integerSchema(minimum: 0),
      ],
      required: ["matches", "skipped_file_count"]
    )
  )

  private static let readProjectFile = Tool(
    name: MCPServiceToolName.readProjectFile.rawValue,
    title: "Read project file",
    description:
      "Read up to 10000 lines (capped at 200 KiB per response) from one approved relative "
      + "project path; larger files page via next_start_line.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "relative_path": boundedStringSchema(maximum: 1_024),
        "start_line": integerSchema(minimum: 1),
        "line_count": integerSchema(minimum: 1, maximum: 10_000),
      ],
      required: ["project_id", "relative_path"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "relative_path": stringSchema,
        "start_line": integerSchema(minimum: 1),
        "end_line": integerSchema(minimum: 1),
        "content": stringSchema,
        "redacted_line_count": integerSchema(minimum: 0),
        "truncated": boolSchema,
        "next_start_line": integerSchema(minimum: 1),
        "sha256": stringSchema,
        "byte_count": integerSchema(minimum: 0),
        "file_revision": stringSchema,
      ],
      required: [
        "relative_path", "start_line", "content", "redacted_line_count", "truncated",
        "sha256", "byte_count", "file_revision",
      ]
    )
  )

  private static let listThreads = Tool(
    name: MCPServiceToolName.listThreads.rawValue,
    title: "List Codex threads",
    description: "List Codex Threads whose cwd exactly matches an approved project.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "cursor": nullableStringSchema(maximum: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 100),
        "search": nullableStringSchema(maximum: 200),
      ],
      required: ["project_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "threads": arraySchema(threadSchema),
        "next_cursor": stringSchema,
      ],
      required: ["threads"]
    )
  )

  private static let readThread = Tool(
    name: MCPServiceToolName.readThread.rawValue,
    title: "Read Codex thread",
    description: "Read a bounded page from a project-bound Codex Thread.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "thread_id": boundedStringSchema(maximum: 1_024),
        "detail": ["type": "string", "enum": ["summary", "full"]],
        "cursor": nullableStringSchema(maximum: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 100),
      ],
      required: ["project_id", "thread_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "thread": threadSchema,
        "detail": ["type": "string", "enum": ["summary", "full"]],
        "entries": arraySchema(threadEntrySchema),
        "next_cursor": stringSchema,
      ],
      required: ["thread", "detail", "entries"]
    )
  )

  private static let listModels = Tool(
    name: MCPServiceToolName.listModels.rawValue,
    title: "List Codex models",
    description: "List current Codex models and advertised reasoning efforts.",
    inputSchema: objectSchema(properties: [:]),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["models": arraySchema(modelSchema)],
      required: ["models"]
    )
  )

  private static let listSkills = Tool(
    name: MCPServiceToolName.listSkills.rawValue,
    title: "List skills",
    description: "List safe, locally discoverable Skills available to the approved project.",
    inputSchema: objectSchema(
      properties: ["project_id": nullableStringSchema(maximum: 128)]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["skills": arraySchema(skillSchema)],
      required: ["skills"]
    )
  )

  private static let readSkill = Tool(
    name: MCPServiceToolName.readSkill.rawValue,
    title: "Read skill",
    description: "Read bounded instructions or reference material from a discovered Skill.",
    inputSchema: objectSchema(
      properties: [
        "skill_name": boundedStringSchema(maximum: 128),
        "project_id": nullableStringSchema(maximum: 128),
        "subpath": nullableStringSchema(maximum: 1_024),
      ],
      required: ["skill_name"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "name": stringSchema,
        "subpath": stringSchema,
        "content": stringSchema,
        "byte_count": integerSchema(minimum: 0),
      ],
      required: ["name", "subpath", "content", "byte_count"]
    )
  )

  private static let runSkillAction = Tool(
    name: MCPServiceToolName.runSkillAction.rawValue,
    title: "Run skill action",
    description:
      "Run a discovered Skill script through the project's existing Direct command policy. "
      + "Use only when the user explicitly requests local Skill script execution.",
    inputSchema: objectSchema(
      properties: [
        "skill_name": boundedStringSchema(maximum: 128),
        "action_name": boundedStringSchema(maximum: 128),
        "arguments": arraySchema(boundedStringSchema(maximum: 4_096)),
        "project_id": boundedStringSchema(maximum: 128),
        "yield_time_ms": integerSchema(minimum: 0, maximum: 60_000),
        "timeout_ms": integerSchema(minimum: 1, maximum: 3_600_000),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["skill_name", "action_name", "project_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "session_id": stringSchema,
        "status": stringSchema,
        "exit_code": nullableStringSchema(maximum: 32),
        "started_at": stringSchema,
        "output": directCommandOutputSchema,
      ],
      required: ["session_id", "status"]
    )
  )

  private static let getTask = Tool(
    name: MCPServiceToolName.getTask.rawValue,
    title: "Get task",
    description: "Read direct task state, recent events, result and Supervisor state.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "recent_event_limit": integerSchema(minimum: 1, maximum: 50),
      ],
      required: ["task_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["task": taskSchema],
      required: ["task"]
    )
  )

  private static let submitTask = Tool(
    name: MCPServiceToolName.submitTask.rawValue,
    title: "Submit task",
    description:
      "Create a Codex task that remains pending until the local user approves it. "
      + "Codex is the default execution path. Prefer this tool unless the user explicitly asked "
      + "ChatGPT to modify files or run commands directly.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "prompt": boundedStringSchema(maximum: 32 * 1_024),
        "skill_name": nullableStringSchema(maximum: 128),
        "thread_id": nullableStringSchema(maximum: 1_024),
        "execution_model": nullableStringSchema(maximum: 256),
        "execution_effort": nullableStringSchema(maximum: 64),
        "supervisor_model": nullableStringSchema(maximum: 256),
        "supervisor_effort": nullableStringSchema(maximum: 64),
        "permission_mode": [
          "type": ["string", "null"],
          "enum": ["read-only", "workspace-write", .null],
        ],
        "network_access": boolSchema,
        "acceptance_criteria": [
          "type": "array",
          "maxItems": 32,
          "items": boundedStringSchema(maximum: 4_096),
        ],
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "prompt"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "task_id": stringSchema,
        "status": stringSchema,
        "reused_existing_task": boolSchema,
        "local_approval_required": boolSchema,
      ],
      required: [
        "task_id", "status", "reused_existing_task", "local_approval_required",
      ]
    )
  )

  private static let steerTask = Tool(
    name: MCPServiceToolName.steerTask.rawValue,
    title: "Steer task",
    description: "Send bounded corrective input to the exact active Codex Turn.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "expected_turn_id": boundedStringSchema(maximum: 1_024),
        "input": boundedStringSchema(maximum: 32 * 1_024),
      ],
      required: ["task_id", "expected_turn_id", "input"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  private static let interruptTask = Tool(
    name: MCPServiceToolName.interruptTask.rawValue,
    title: "Interrupt task",
    description: "Request interruption of the exact active Codex Turn.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "expected_turn_id": boundedStringSchema(maximum: 1_024),
      ],
      required: ["task_id", "expected_turn_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  private static let mutationOutputSchema = outputSchema(
    properties: [
      "task_id": stringSchema,
      "status": stringSchema,
      "accepted": boolSchema,
    ],
    required: ["task_id", "status", "accepted"]
  )

  private static let directMutationOutputSchema = outputSchema(
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

  private static let directMutationReceiptSchema = objectSchema(
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

  private static let directManagePathOutputSchema = outputSchema(
    properties: [
      "relative_path": stringSchema,
      "operation": stringSchema,
      "old_sha256": stringSchema,
      "new_sha256": stringSchema,
      "byte_count": integerSchema(minimum: 0),
    ],
    required: ["relative_path", "operation", "byte_count"]
  )

  private static let getProjectChanges = Tool(
    name: MCPServiceToolName.getProjectChanges.rawValue,
    title: "Get project changes",
    description: "Read bounded Git status and diff for an approved project. Observation only.",
    inputSchema: projectIDInput,
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "changed_files": arraySchema(stringSchema),
        "diff": stringSchema,
        "additions": integerSchema(minimum: 0),
        "deletions": integerSchema(minimum: 0),
        "truncated": boolSchema,
        "not_git_repository": boolSchema,
      ],
      required: [
        "changed_files", "diff", "additions", "deletions", "truncated", "not_git_repository",
      ]
    )
  )

  private static let listProjectCommands = Tool(
    name: MCPServiceToolName.listProjectCommands.rawValue,
    title: "List project commands",
    description:
      "Read the registered Direct commands and the command mode for an approved project. "
      + "These commands only run when the user explicitly asks ChatGPT to execute them locally.",
    inputSchema: projectIDInput,
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "command_mode": ["type": "string", "enum": ["denied", "registered", "safe"]],
        "commands": arraySchema(projectCommandSchema),
      ],
      required: ["command_mode", "commands"]
    )
  )

  private static let directWriteProjectFile = Tool(
    name: MCPServiceToolName.directWriteProjectFile.rawValue,
    title: "Direct write project file",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks ChatGPT itself "
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

  private static let directEditProjectFile = Tool(
    name: MCPServiceToolName.directEditProjectFile.rawValue,
    title: "Direct edit project file",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks ChatGPT itself "
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

  private static let directApplyProjectPatch = Tool(
    name: MCPServiceToolName.directApplyProjectPatch.rawValue,
    title: "Direct apply project patch",
    description:
      "Explicit Direct Workspace action. Use only when the user explicitly asks ChatGPT itself "
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

  private static let directManageProjectPath = Tool(
    name: MCPServiceToolName.directManageProjectPath.rawValue,
    title: "Direct manage project path",
    description:
      "Explicit Direct Workspace destructive action. Use only when the user explicitly asks "
      + "ChatGPT itself to move or delete files. Deleting and moving require the current file "
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

  private static let directExecProjectCommand = Tool(
    name: MCPServiceToolName.directExecCommand.rawValue,
    title: "Direct execute project command",
    description:
      "Explicit Direct Workspace action that runs a user-registered project command (or a "
      + "built-in safe command) on the local machine. Use only when the user explicitly asks "
      + "ChatGPT itself to run a command inside the project. The session streams bounded "
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
    outputSchema: directCommandOutputSchema
  )

  private static let directReadCommand = Tool(
    name: MCPServiceToolName.directReadCommand.rawValue,
    title: "Read direct command",
    description:
      "Read the latest bounded output of a direct command session. Use only when the user "
      + "explicitly asked ChatGPT to run commands directly and this session was started with "
      + "direct_exec_project_command.",
    inputSchema: objectSchema(
      properties: ["session_id": boundedStringSchema(maximum: 128)],
      required: ["session_id"]
    ),
    annotations: readAnnotations,
    outputSchema: directCommandOutputSchema
  )

  private static let directWriteStdin = Tool(
    name: MCPServiceToolName.directWriteStdin.rawValue,
    title: "Write direct command stdin",
    description:
      "Write a bounded chunk of input to the stdin of a running interactive direct command "
      + "session. Use only when the user explicitly asked ChatGPT to drive an interactive "
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
    outputSchema: objectSchema(properties: [:])
  )

  private static let directInterruptCommand = Tool(
    name: MCPServiceToolName.directInterruptCommand.rawValue,
    title: "Interrupt direct command",
    description:
      "Cancel a running direct command session, terminating its process group. Use only when "
      + "the user explicitly asked ChatGPT to run commands directly and the session must stop.",
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

  private static let directCommandOutputSchema = objectSchema(
    properties: [
      "session_id": stringSchema,
      "status": stringSchema,
      "exit_code": nullableStringSchema(maximum: 32),
      "timed_out": boolSchema,
      "head": stringSchema,
      "tail": stringSchema,
      "byte_count": integerSchema(minimum: 0),
      "truncated": boolSchema,
    ],
    required: ["session_id", "status", "timed_out", "head", "tail", "byte_count", "truncated"]
  )

  private static let directGitCommit = Tool(
    name: MCPServiceToolName.directGitCommit.rawValue,
    title: "Direct git commit",
    description:
      "Explicit Direct Workspace action that creates a local Git commit inside the project. "
      + "Use only when the user explicitly asks ChatGPT itself to commit the changes. It stages "
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
    outputSchema: objectSchema(
      properties: [
        "commit_hash": nullableStringSchema(maximum: 64),
        "changed_files": arraySchema(boundedStringSchema(maximum: 1_024)),
        "summary": stringSchema,
        "exit_code": integerSchema(minimum: 0),
      ],
      required: ["changed_files", "summary", "exit_code"]
    )
  )

  private static let projectIDInput = objectSchema(
    properties: ["project_id": boundedStringSchema(maximum: 128)],
    required: ["project_id"]
  )

  private static let capabilitiesSchema = objectSchema(
    properties: [
      "read": stringSchema,
      "write": stringSchema,
      "network": stringSchema,
    ],
    required: ["read", "write", "network"]
  )

  private static let projectSummarySchema = objectSchema(
    properties: [
      "project_id": stringSchema,
      "name": stringSchema,
      "capabilities": capabilitiesSchema,
      "git_state": stringSchema,
    ],
    required: ["project_id", "name", "capabilities"]
  )

  private static let projectDetailSchema = objectSchema(
    properties: [
      "project_id": stringSchema,
      "name": stringSchema,
      "capabilities": capabilitiesSchema,
      "git_state": stringSchema,
      "verification_commands": arraySchema(stringSchema),
      "thread_count": integerSchema(minimum: 0),
      "direct_workspace": objectSchema(
        properties: [
          "file_write_permission": stringSchema,
          "command_mode": ["type": "string", "enum": ["denied", "registered", "safe"]],
          "commands": arraySchema(projectCommandSchema),
        ],
        required: ["file_write_permission", "command_mode", "commands"]
      ),
    ],
    required: ["project_id", "name", "capabilities", "verification_commands"]
  )

  private static let searchMatchSchema = objectSchema(
    properties: [
      "relative_path": stringSchema,
      "line_number": integerSchema(minimum: 1),
      "preview": stringSchema,
      "redacted": boolSchema,
    ],
    required: ["relative_path", "line_number", "preview", "redacted"]
  )

  private static let projectCommandSchema = objectSchema(
    properties: [
      "command_id": stringSchema,
      "name": stringSchema,
      "executable": stringSchema,
      "arguments": arraySchema(stringSchema),
      "working_directory": stringSchema,
      "requires_network": boolSchema,
      "risk": ["type": "string", "enum": ["normal", "elevated"]],
    ],
    required: ["command_id", "name", "executable", "arguments", "risk"]
  )

  private static let threadSchema = objectSchema(
    properties: [
      "thread_id": stringSchema,
      "title": stringSchema,
      "status": stringSchema,
      "updated_at": stringSchema,
      "preview": stringSchema,
    ],
    required: ["thread_id", "status"]
  )

  private static let threadEntrySchema = objectSchema(
    properties: [
      "turn_id": stringSchema,
      "role": stringSchema,
      "text": stringSchema,
      "status": stringSchema,
    ],
    required: ["turn_id", "role", "text"]
  )

  private static let modelSchema = objectSchema(
    properties: [
      "model_id": stringSchema,
      "display_name": stringSchema,
      "is_default": boolSchema,
      "reasoning_efforts": arraySchema(stringSchema),
      "default_reasoning_effort": stringSchema,
      "service_tiers": arraySchema(stringSchema),
      "additional_speed_tiers": arraySchema(stringSchema),
    ],
    required: ["model_id", "display_name", "is_default", "reasoning_efforts"]
  )

  private static let skillSchema = objectSchema(
    properties: [
      "name": stringSchema,
      "description": stringSchema,
      "scope": ["type": "string", "enum": ["project", "global"]],
      "triggers": arraySchema(stringSchema),
      "actions": arraySchema(skillActionSchema),
      "has_references": boolSchema,
    ],
    required: ["name", "description", "scope", "triggers", "actions", "has_references"]
  )

  private static let skillActionSchema = objectSchema(
    properties: [
      "name": stringSchema,
      "script_path": stringSchema,
      "interpreter": nullableStringSchema(maximum: 4_096),
      "requires_network": boolSchema,
      "network_requirement": [
        "type": "string", "enum": ["denied", "required", "unspecified"],
      ],
      "description": stringSchema,
    ],
    required: [
      "name", "script_path", "interpreter", "requires_network", "network_requirement",
      "description",
    ]
  )

  private static let taskEventSchema = objectSchema(
    properties: [
      "seq": integerSchema(minimum: 0),
      "kind": stringSchema,
      "summary": stringSchema,
      "occurred_at": stringSchema,
    ],
    required: ["seq", "kind", "summary", "occurred_at"]
  )

  private static let taskSchema = objectSchema(
    properties: [
      "task_id": stringSchema,
      "project_id": stringSchema,
      "status": stringSchema,
      "thread_id": stringSchema,
      "turn_id": stringSchema,
      "current_step": stringSchema,
      "changed_files": arraySchema(stringSchema),
      "recent_events": arraySchema(taskEventSchema),
      "supervisor_status": stringSchema,
      "supervisor_summary": stringSchema,
      "local_approval_required": boolSchema,
      "result_summary": stringSchema,
      "failure_code": stringSchema,
      "updated_at": stringSchema,
    ],
    required: [
      "task_id", "project_id", "status", "changed_files", "recent_events",
      "supervisor_status", "local_approval_required", "updated_at",
    ]
  )

  private static let errorSchema = objectSchema(
    properties: [
      "code": stringSchema,
      "message": stringSchema,
      "retryable": boolSchema,
    ],
    required: ["code", "message", "retryable"]
  )

  private static let stringSchema: Value = ["type": "string"]
  private static let boolSchema: Value = ["type": "boolean"]

  private static func boundedStringSchema(maximum: Int) -> Value {
    ["type": "string", "maxLength": .int(maximum)]
  }

  private static func nullableStringSchema(maximum: Int) -> Value {
    ["type": ["string", "null"], "maxLength": .int(maximum)]
  }

  private static func integerSchema(minimum: Int, maximum: Int? = nil) -> Value {
    var result: [String: Value] = ["type": "integer", "minimum": .int(minimum)]
    if let maximum { result["maximum"] = .int(maximum) }
    return .object(result)
  }

  private static func arraySchema(_ item: Value) -> Value {
    ["type": "array", "items": item]
  }

  private static func objectSchema(
    properties: [String: Value],
    required: [String] = []
  ) -> Value {
    var result: [String: Value] = [
      "type": "object",
      "properties": .object(properties),
      "additionalProperties": false,
    ]
    if !required.isEmpty {
      result["required"] = .array(required.map(Value.string))
    }
    return .object(result)
  }

  private static func outputSchema(
    properties: [String: Value],
    required: [String]
  ) -> Value {
    var fields = properties
    fields["schema_version"] = ["type": "integer", "const": 1]
    fields["error"] = errorSchema
    guard case .object(var result) = objectSchema(properties: fields, required: ["schema_version"])
    else {
      preconditionFailure("Output schema must be an object.")
    }
    result["oneOf"] = [
      ["required": .array(required.map(Value.string))],
      ["required": ["error"]],
    ]
    return .object(result)
  }
}
