import MCP

public enum MCPToolName: String, CaseIterable, Sendable {
  case bridgeStatus = "bridge_status"
  case listProjects = "list_projects"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listModels = "list_models"
}

public enum MCPTaskToolName: String, CaseIterable, Sendable {
  case getTask = "get_task"
  case getTaskEvents = "get_task_events"
  case getTaskDiff = "get_task_diff"
  case getFinalReport = "get_final_report"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
}

public enum MCPProjectToolName: String, CaseIterable, Sendable {
  case getProject = "get_project"
  case searchProjectFiles = "search_project_files"
  case readProjectFile = "read_project_file"
  case openInCodex = "open_in_codex"
}

enum MCPDispatchedToolName: String, Sendable {
  case bridgeStatus = "bridge_status"
  case listProjects = "list_projects"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listModels = "list_models"
  case getTask = "get_task"
  case getTaskEvents = "get_task_events"
  case getTaskDiff = "get_task_diff"
  case getFinalReport = "get_final_report"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
  case getProject = "get_project"
  case searchProjectFiles = "search_project_files"
  case readProjectFile = "read_project_file"
  case openInCodex = "open_in_codex"
}

public struct MCPToolCatalog: Sendable {
  public let definitions: [Tool]

  public init(includeTaskTools: Bool = false, includeProjectTools: Bool = false) {
    let readOnlyDefinitions = [
      Self.bridgeStatus,
      Self.listProjects,
      Self.listThreads,
      Self.readThread,
      Self.listModels,
    ]
    let taskDefinitions = [
      Self.getTask,
      Self.getTaskEvents,
      Self.getTaskDiff,
      Self.getFinalReport,
      Self.submitTask,
      Self.steerTask,
      Self.interruptTask,
    ]
    let projectDefinitions = [
      Self.getProject,
      Self.searchProjectFiles,
      Self.readProjectFile,
      Self.openInCodex,
    ]
    definitions =
      readOnlyDefinitions
      + (includeProjectTools ? projectDefinitions : [])
      + (includeTaskTools ? taskDefinitions : [])
  }

  private static let annotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let bridgeStatus = Tool(
    name: MCPToolName.bridgeStatus.rawValue,
    title: "Bridge status",
    description: "Read the health and capability state of the local Codex Bridge.",
    inputSchema: emptyInputSchema,
    annotations: annotations,
    outputSchema: outputSchema(
      properties: [
        "app_version": stringSchema,
        "mcp_state": stringSchema,
        "tunnel_state": stringSchema,
        "codex_version": stringSchema,
        "login_mode": stringSchema,
        "execution_state": stringSchema,
        "supervisor_state": stringSchema,
        "degradations": arraySchema(items: stringSchema),
        "pending_approval_count": integerSchema(minimum: 0),
      ],
      required: [
        "app_version", "mcp_state", "tunnel_state", "execution_state", "supervisor_state",
        "degradations", "pending_approval_count",
      ]
    )
  )

  private static let listProjects = Tool(
    name: MCPToolName.listProjects.rawValue,
    title: "List projects",
    description: "List user-approved projects that are visible through MCP.",
    inputSchema: paginatedInputSchema,
    annotations: annotations,
    outputSchema: outputSchema(
      properties: [
        "projects": arraySchema(items: projectSchema),
        "next_cursor": stringSchema,
      ],
      required: ["projects"]
    )
  )

  private static let listThreads = Tool(
    name: MCPToolName.listThreads.rawValue,
    title: "List Codex threads",
    description: "List Codex threads bound to one approved project.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maxLength: 128),
        "cursor": nullableStringSchema(maxLength: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 100),
        "search": nullableStringSchema(maxLength: 200),
      ],
      required: ["project_id"]
    ),
    annotations: annotations,
    outputSchema: outputSchema(
      properties: [
        "threads": arraySchema(items: threadSchema),
        "next_cursor": stringSchema,
      ],
      required: ["threads"]
    )
  )

  private static let readThread = Tool(
    name: MCPToolName.readThread.rawValue,
    title: "Read Codex thread",
    description: "Read a summary or one bounded page of a project-bound Codex thread.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maxLength: 128),
        "thread_id": boundedStringSchema(maxLength: 256),
        "detail": ["type": "string", "enum": ["summary", "full"]],
        "cursor": nullableStringSchema(maxLength: 2_048),
        "limit": integerSchema(minimum: 1, maximum: 100),
      ],
      required: ["project_id", "thread_id"]
    ),
    annotations: annotations,
    outputSchema: outputSchema(
      properties: [
        "thread": threadSchema,
        "detail": ["type": "string", "enum": ["summary", "full"]],
        "entries": arraySchema(items: threadEntrySchema),
        "next_cursor": stringSchema,
      ],
      required: ["thread", "detail", "entries"]
    )
  )

  private static let listModels = Tool(
    name: MCPToolName.listModels.rawValue,
    title: "List Codex models",
    description: "List current Codex model IDs and their advertised reasoning efforts.",
    inputSchema: emptyInputSchema,
    annotations: annotations,
    outputSchema: outputSchema(
      properties: [
        "models": arraySchema(items: modelSchema)
      ],
      required: ["models"]
    )
  )

  private static let emptyInputSchema = objectSchema(properties: [:])

  private static let paginatedInputSchema = objectSchema(
    properties: [
      "cursor": nullableStringSchema(maxLength: 2_048),
      "limit": integerSchema(minimum: 1, maximum: 100),
    ]
  )

  private static let projectSchema = objectSchema(
    properties: [
      "project_id": stringSchema,
      "name": stringSchema,
      "capabilities": objectSchema(
        properties: [
          "read": stringSchema,
          "write": stringSchema,
          "network": stringSchema,
        ],
        required: ["read", "write", "network"]
      ),
      "git_state": stringSchema,
    ],
    required: ["project_id", "name", "capabilities"]
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
      "is_default": ["type": "boolean"],
      "reasoning_efforts": arraySchema(items: stringSchema),
      "default_reasoning_effort": stringSchema,
    ],
    required: ["model_id", "display_name", "is_default", "reasoning_efforts"]
  )

  private static let errorSchema = objectSchema(
    properties: [
      "code": stringSchema,
      "message": stringSchema,
      "retryable": ["type": "boolean"],
    ],
    required: ["code", "message", "retryable"]
  )

  private static let stringSchema: Value = ["type": "string"]

  private static func boundedStringSchema(maxLength: Int) -> Value {
    ["type": "string", "maxLength": .int(maxLength)]
  }

  private static func nullableStringSchema(maxLength: Int) -> Value {
    [
      "type": ["string", "null"],
      "maxLength": .int(maxLength),
    ]
  }

  private static func integerSchema(minimum: Int, maximum: Int? = nil) -> Value {
    var schema: [String: Value] = [
      "type": "integer",
      "minimum": .int(minimum),
    ]
    if let maximum {
      schema["maximum"] = .int(maximum)
    }
    return .object(schema)
  }

  private static func arraySchema(items: Value) -> Value {
    ["type": "array", "items": items]
  }

  private static func objectSchema(
    properties: [String: Value],
    required: [String] = []
  ) -> Value {
    var schema: [String: Value] = [
      "type": "object",
      "properties": .object(properties),
      "additionalProperties": false,
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(Value.string))
    }
    return .object(schema)
  }

  private static func outputSchema(
    properties: [String: Value],
    required: [String]
  ) -> Value {
    var allProperties = properties
    allProperties["schema_version"] = ["type": "integer", "const": 1]
    allProperties["error"] = errorSchema
    guard
      case .object(var schema) = objectSchema(
        properties: allProperties,
        required: ["schema_version"]
      )
    else {
      preconditionFailure("Object schema construction must return an object.")
    }
    schema["oneOf"] = [
      ["required": .array(required.map(Value.string))],
      ["required": ["error"]],
    ]
    return .object(schema)
  }
}
