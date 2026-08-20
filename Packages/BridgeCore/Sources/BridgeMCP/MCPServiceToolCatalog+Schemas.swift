import MCP

extension MCPServiceToolCatalog {
  static let projectIDInput = objectSchema(
    properties: ["project_id": boundedStringSchema(maximum: 128)],
    required: ["project_id"]
  )

  static let capabilitiesSchema = objectSchema(
    properties: [
      "read": stringSchema,
      "write": stringSchema,
      "network": stringSchema,
    ],
    required: ["read", "write", "network"]
  )

  static let projectSummarySchema = objectSchema(
    properties: [
      "project_id": stringSchema,
      "name": stringSchema,
      "capabilities": capabilitiesSchema,
      "git_state": stringSchema,
    ],
    required: ["project_id", "name", "capabilities"]
  )

  static let projectDetailSchema = objectSchema(
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
          "command_mode": ["type": "string", "enum": ["denied", "safe", "full"]],
          "commands": arraySchema(projectCommandSchema),
        ],
        required: ["file_write_permission", "command_mode", "commands"]
      ),
    ],
    required: ["project_id", "name", "capabilities", "verification_commands"]
  )

  static let searchMatchSchema = objectSchema(
    properties: [
      "relative_path": stringSchema,
      "line_number": integerSchema(minimum: 1),
      "preview": stringSchema,
      "redacted": boolSchema,
    ],
    required: ["relative_path", "line_number", "preview", "redacted"]
  )

  static let projectCommandSchema = objectSchema(
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

  static let builtInCommandSchema = objectSchema(
    properties: [
      "executable": stringSchema,
      "arguments_prefix": arraySchema(stringSchema),
      "allows_additional_arguments": boolSchema,
      "requires_network": boolSchema,
    ],
    required: [
      "executable", "arguments_prefix", "allows_additional_arguments", "requires_network",
    ]
  )

  static let threadSchema = objectSchema(
    properties: [
      "thread_id": stringSchema,
      "title": stringSchema,
      "status": stringSchema,
      "updated_at": stringSchema,
      "preview": stringSchema,
    ],
    required: ["thread_id", "status"]
  )

  static let threadEntrySchema = objectSchema(
    properties: [
      "turn_id": stringSchema,
      "role": stringSchema,
      "text": stringSchema,
      "status": stringSchema,
    ],
    required: ["turn_id", "role", "text"]
  )

  static let modelSchema = objectSchema(
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

  static let skillSchema = objectSchema(
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

  static let skillActionSchema = objectSchema(
    properties: [
      "name": stringSchema,
      "script_path": stringSchema,
      "interpreter": nullableStringSchema(maximum: 4_096),
      "command_prefix": arraySchema(stringSchema),
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

  static let taskEventSchema = objectSchema(
    properties: [
      "seq": integerSchema(minimum: 0),
      "kind": stringSchema,
      "summary": stringSchema,
      "occurred_at": stringSchema,
    ],
    required: ["seq", "kind", "summary", "occurred_at"]
  )

  static let taskSchema = objectSchema(
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

  static let errorSchema = objectSchema(
    properties: [
      "code": stringSchema,
      "message": stringSchema,
      "retryable": boolSchema,
    ],
    required: ["code", "message", "retryable"]
  )

  static let stringSchema: Value = ["type": "string"]
  static let boolSchema: Value = ["type": "boolean"]

  static func boundedStringSchema(maximum: Int) -> Value {
    ["type": "string", "maxLength": .int(maximum)]
  }

  static func nullableStringSchema(maximum: Int) -> Value {
    ["type": ["string", "null"], "maxLength": .int(maximum)]
  }

  static func integerSchema(minimum: Int, maximum: Int? = nil) -> Value {
    var result: [String: Value] = ["type": "integer", "minimum": .int(minimum)]
    if let maximum { result["maximum"] = .int(maximum) }
    return .object(result)
  }

  static func arraySchema(_ item: Value) -> Value {
    ["type": "array", "items": item]
  }

  static func objectSchema(
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

  static func outputSchema(
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
