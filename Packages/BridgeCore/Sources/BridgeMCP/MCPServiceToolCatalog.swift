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
  case getTask = "get_task"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
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
      Self.getTask,
    ]
    if exposureMode == .full {
      tools.append(contentsOf: [Self.submitTask, Self.steerTask, Self.interruptTask])
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
    description: "Read a bounded page from one approved relative project path.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "relative_path": boundedStringSchema(maximum: 1_024),
        "start_line": integerSchema(minimum: 1),
        "line_count": integerSchema(minimum: 1, maximum: 300),
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
      ],
      required: [
        "relative_path", "start_line", "content", "redacted_line_count", "truncated",
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
    description: "Create a Codex task that remains pending until the local user approves it.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "prompt": boundedStringSchema(maximum: 32 * 1_024),
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
    ],
    required: ["model_id", "display_name", "is_default", "reasoning_efforts"]
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
