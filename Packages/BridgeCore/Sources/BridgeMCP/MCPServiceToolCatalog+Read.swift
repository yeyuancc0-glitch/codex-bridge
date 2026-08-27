import MCP

extension MCPServiceToolCatalog {
  static let readAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  static let bridgeStatus = Tool(
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
        "execution_environment": executionEnvironmentSchema,
      ],
      required: [
        "app_version", "mcp_state", "tunnel_state", "execution_state", "supervisor_state",
        "degradations", "pending_approval_count",
      ]
    )
  )

  static let listProjects = Tool(
    name: MCPServiceToolName.listProjects.rawValue,
    title: "List projects",
    description: "List user-approved projects visible to the authenticated MCP client.",
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

  static let listAgents = Tool(
    name: MCPServiceToolName.listAgents.rawValue,
    title: "List registered Agent installations",
    description:
      "List user-registered Agent installations and their persisted Probe results. "
      + "A selectable OpenCode installation can receive tasks through submit_task; DeepSeek "
      + "Harness is experimental and supports fresh sessions with provider-native read-only or "
      + "workspace-write modes. Selectable OpenCode and Antigravity installations can receive "
      + "explicit provider tasks through submit_task. The local user still approves each task "
      + "before execution, while "
      + "DeepSeek execution-time permission requests are surfaced for one-shot local approval; "
      + "steer input is queued as a follow-up on the same session. "
      + "Inspect network_enforcement: unavailable means network_access=false "
      + "does not guarantee blocking the Provider model control plane or shell-tool network.",
    inputSchema: objectSchema(
      properties: ["project_id": optionalOpaqueProjectIDSchema]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["agents": arraySchema(agentSummarySchema)],
      required: ["agents"]
    )
  )

  static let getProject = Tool(
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

  static let searchProjectFiles = Tool(
    name: MCPServiceToolName.searchProjectFiles.rawValue,
    title: "Search project files",
    description: "Search bounded text inside one approved project.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
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

  static let readProjectFile = Tool(
    name: MCPServiceToolName.readProjectFile.rawValue,
    title: "Read project file",
    description:
      "Read up to 10000 lines (capped at 200 KiB per response) from one approved relative "
      + "project path; larger files page via next_start_line.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
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

  static let listThreads = Tool(
    name: MCPServiceToolName.listThreads.rawValue,
    title: "List Codex threads",
    description:
      "List Codex Threads whose cwd exactly matches an approved project. An empty threads array "
      + "is a valid result and means no matching Thread is currently available.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
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

  static let readThread = Tool(
    name: MCPServiceToolName.readThread.rawValue,
    title: "Read Codex thread",
    description:
      "Read a bounded page from a project-bound Codex Thread. Use only a thread_id returned by "
      + "list_threads for the same project_id. Known missing or invalid IDs return thread_not_found; "
      + "a Codex component or process failure remains unavailable.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
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

  static let listModels = Tool(
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

  static let listSkills = Tool(
    name: MCPServiceToolName.listSkills.rawValue,
    title: "List skills",
    description: "List safe, locally discoverable Skills available to the approved project.",
    inputSchema: objectSchema(
      properties: ["project_id": optionalOpaqueProjectIDSchema]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["skills": arraySchema(skillSchema)],
      required: ["skills"]
    )
  )

  static let readSkill = Tool(
    name: MCPServiceToolName.readSkill.rawValue,
    title: "Read skill",
    description: "Read bounded instructions or reference material from a discovered Skill.",
    inputSchema: objectSchema(
      properties: [
        "skill_name": boundedStringSchema(maximum: 128),
        "project_id": optionalOpaqueProjectIDSchema,
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

  static let getProjectChanges = Tool(
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

  static let listProjectCommands = Tool(
    name: MCPServiceToolName.listProjectCommands.rawValue,
    title: "List project commands",
    description:
      "Read the built-in safe rules, registered Direct commands, and command mode for an approved project. "
      + "These commands only run when the user explicitly asks the MCP client to execute them locally. "
      + "Use recommended_usage to copy an allowed argv and command_id when present without guessing executables.",
    inputSchema: projectIDInput,
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "command_mode": ["type": "string", "enum": ["denied", "safe", "full"]],
        "built_in_commands": arraySchema(builtInCommandSchema),
        "registered_commands": arraySchema(projectCommandSchema),
        "commands": arraySchema(projectCommandSchema),
        "recommended_usage": [
          "type": "object",
          "additionalProperties": objectSchema(
            properties: [
              "command_id": stringSchema,
              "argv": arraySchema(stringSchema),
              "working_directory": stringSchema,
            ],
            required: ["argv"]
          ),
        ],
      ],
      required: [
        "command_mode", "built_in_commands", "registered_commands", "commands",
        "recommended_usage",
      ]
    )
  )
}
