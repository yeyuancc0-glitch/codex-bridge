import MCP

extension MCPToolCatalog {
  static let getProject = Tool(
    name: MCPProjectToolName.getProject.rawValue,
    title: "Get project",
    description: "Read bounded capabilities and verification metadata for one approved project.",
    inputSchema: projectIDInput,
    annotations: projectReadAnnotations,
    outputSchema: projectOutput(
      properties: ["project": projectDetailSchema],
      required: ["project"]
    )
  )

  static let searchProjectFiles = Tool(
    name: MCPProjectToolName.searchProjectFiles.rawValue,
    title: "Search project files",
    description: "Search bounded text in one approved project and return relative paths only.",
    inputSchema: projectObject(
      properties: [
        "project_id": projectBoundedString(128),
        "query": projectBoundedString(512),
        "relative_directory": projectNullableString(1_024),
        "case_sensitive": ["type": "boolean"],
        "cursor": projectNullableString(128),
        "limit": projectInteger(minimum: 1, maximum: 50),
      ],
      required: ["project_id", "query"]
    ),
    annotations: projectReadAnnotations,
    outputSchema: projectOutput(
      properties: [
        "matches": projectArray(searchMatchSchema),
        "next_cursor": projectString,
        "skipped_file_count": projectInteger(minimum: 0),
      ],
      required: ["matches", "skipped_file_count"]
    )
  )

  static let readProjectFile = Tool(
    name: MCPProjectToolName.readProjectFile.rawValue,
    title: "Read project file",
    description: "Read at most 300 lines and 200 KiB from one approved relative project path.",
    inputSchema: projectObject(
      properties: [
        "project_id": projectBoundedString(128),
        "relative_path": projectBoundedString(1_024),
        "start_line": projectInteger(minimum: 1),
        "line_count": projectInteger(minimum: 1, maximum: 300),
      ],
      required: ["project_id", "relative_path"]
    ),
    annotations: projectReadAnnotations,
    outputSchema: projectOutput(
      properties: [
        "relative_path": projectString,
        "start_line": projectInteger(minimum: 1),
        "end_line": projectInteger(minimum: 1),
        "content": projectString,
        "redacted_line_count": projectInteger(minimum: 0),
        "truncated": ["type": "boolean"],
        "next_start_line": projectInteger(minimum: 1),
      ],
      required: [
        "relative_path", "start_line", "content", "redacted_line_count", "truncated",
      ]
    )
  )

  static let openInCodex = Tool(
    name: MCPProjectToolName.openInCodex.rawValue,
    title: "Open in Codex",
    description: "Navigate the local Codex app to a verified project-bound thread.",
    inputSchema: projectObject(
      properties: [
        "project_id": projectBoundedString(128),
        "thread_id": projectBoundedString(256),
      ],
      required: ["project_id", "thread_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    ),
    outputSchema: projectOutput(
      properties: [
        "project_id": projectString,
        "thread_id": projectString,
        "opened": ["type": "boolean"],
      ],
      required: ["project_id", "thread_id", "opened"]
    )
  )

  private static let projectReadAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let projectIDInput = projectObject(
    properties: ["project_id": projectBoundedString(128)],
    required: ["project_id"]
  )

  private static let projectDetailSchema = projectObject(
    properties: [
      "project_id": projectString,
      "name": projectString,
      "capabilities": projectCapabilitiesSchema,
      "git_state": projectString,
      "verification_commands": projectArray(projectString),
      "thread_count": projectInteger(minimum: 0),
    ],
    required: ["project_id", "name", "capabilities", "verification_commands"]
  )

  private static let projectCapabilitiesSchema = projectObject(
    properties: [
      "read": projectString,
      "write": projectString,
      "network": projectString,
    ],
    required: ["read", "write", "network"]
  )

  private static let searchMatchSchema = projectObject(
    properties: [
      "relative_path": projectString,
      "line_number": projectInteger(minimum: 1),
      "preview": projectString,
      "redacted": ["type": "boolean"],
    ],
    required: ["relative_path", "line_number", "preview", "redacted"]
  )

  private static let projectErrorSchema = projectObject(
    properties: [
      "code": projectString,
      "message": projectString,
      "retryable": ["type": "boolean"],
    ],
    required: ["code", "message", "retryable"]
  )

  private static let projectString: Value = ["type": "string"]

  private static func projectBoundedString(_ maximum: Int) -> Value {
    ["type": "string", "maxLength": .int(maximum)]
  }

  private static func projectNullableString(_ maximum: Int) -> Value {
    ["type": ["string", "null"], "maxLength": .int(maximum)]
  }

  private static func projectInteger(minimum: Int, maximum: Int? = nil) -> Value {
    var value: [String: Value] = ["type": "integer", "minimum": .int(minimum)]
    if let maximum { value["maximum"] = .int(maximum) }
    return .object(value)
  }

  private static func projectArray(_ items: Value) -> Value {
    ["type": "array", "items": items]
  }

  private static func projectObject(
    properties: [String: Value],
    required: [String] = []
  ) -> Value {
    var value: [String: Value] = [
      "type": "object",
      "properties": .object(properties),
      "additionalProperties": false,
    ]
    if !required.isEmpty { value["required"] = .array(required.map(Value.string)) }
    return .object(value)
  }

  private static func projectOutput(
    properties: [String: Value],
    required: [String]
  ) -> Value {
    var all = properties
    all["schema_version"] = ["type": "integer", "const": 1]
    all["error"] = projectErrorSchema
    guard
      case .object(var schema) = projectObject(
        properties: all,
        required: ["schema_version"]
      )
    else {
      preconditionFailure("Project tool output schema must be an object.")
    }
    schema["oneOf"] = [
      ["required": .array(required.map(Value.string))],
      ["required": ["error"]],
    ]
    return .object(schema)
  }
}
