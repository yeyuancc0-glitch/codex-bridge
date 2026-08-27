import MCP

extension MCPServiceToolCatalog {
  static let projectIDInput = objectSchema(
    properties: ["project_id": opaqueProjectIDSchema],
    required: ["project_id"]
  )

  static let opaqueProjectIDSchema = MCPSharedToolSchemas.opaqueProjectID
  static let optionalOpaqueProjectIDSchema = MCPSharedToolSchemas.optionalOpaqueProjectID

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

  static let agentSummarySchema = objectSchema(
    properties: [
      "provider_id": [
        "type": "string",
        "description":
          "Provider identifier. deepseek-harness is experimental, read-only, and supports fresh sessions only.",
      ],
      "installation_id": stringSchema,
      "display_name": stringSchema,
      "availability": [
        "type": "string", "enum": ["available", "unavailable", "needs_review"],
      ],
      "enabled": boolSchema,
      "task_submission_enabled": boolSchema,
      "version": stringSchema,
      "protocol_revision": stringSchema,
      "adapter_revision": integerSchema(minimum: 1),
      "effective_capabilities": [
        "type": "array",
        "items": stringSchema,
        "description":
          "Capabilities enforced for this installation. DeepSeek Harness exposes session_create, interrupt, text_delta, and workspace.read only.",
      ],
      "trust_profile": ["type": "string", "enum": ["managed", "user_trusted"]],
      "security_profile_id": stringSchema,
      "workspace_enforcement": stringSchema,
      "approval_enforcement": stringSchema,
      "network_enforcement": [
        "type": "string",
        "description":
          "Bridge enforcement status. unavailable means network_access=false does not guarantee blocking the Provider model control plane or shell-tool network.",
      ],
      "models_summary": arraySchema(stringSchema),
      "unavailable_reason": stringSchema,
      "last_verified_at": stringSchema,
    ],
    required: [
      "provider_id", "installation_id", "display_name", "availability", "enabled",
      "task_submission_enabled", "adapter_revision", "effective_capabilities",
      "trust_profile", "workspace_enforcement", "approval_enforcement",
      "network_enforcement", "models_summary",
    ]
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
      "seq": integerSchema(minimum: 1),
      "kind": stringSchema,
      "summary": stringSchema,
      "occurred_at": stringSchema,
    ],
    required: ["seq", "kind", "summary", "occurred_at"]
  )

  static let taskActivitySchema = objectSchema(
    properties: [
      "seq": integerSchema(minimum: 1),
      "kind": stringSchema,
      "summary": stringSchema,
      "occurred_at": stringSchema,
      "tool_name": stringSchema,
      "tool_status": stringSchema,
    ],
    required: ["seq", "kind", "summary", "occurred_at"]
  )

  static let taskWaitPolicySchema = objectSchema(
    properties: [
      "wait_profile": [
        "type": ["string", "null"],
        "enum": ["fast", "standard", "deep", .null],
      ],
      "recommended_poll_after_seconds": integerSchema(minimum: 0, maximum: 600),
      "diagnostic_after_quiet_seconds": integerSchema(minimum: 0, maximum: 3_600),
      "terminal": boolSchema,
      "next_action": [
        "type": "string",
        "enum": [
          "await_local_approval", "poll_get_task", "read_final_report",
          "inspect_terminal_state", "inspect_task",
        ],
      ],
      "do_not_infer_failure": boolSchema,
    ],
    required: [
      "wait_profile", "recommended_poll_after_seconds", "diagnostic_after_quiet_seconds",
      "terminal", "next_action", "do_not_infer_failure",
    ]
  )

  static let taskSchema = objectSchema(
    properties: [
      "task_id": stringSchema,
      "project_id": stringSchema,
      "status": stringSchema,
      "provider_id": stringSchema,
      "installation_id": stringSchema,
      "execution_model": stringSchema,
      "execution_effort": stringSchema,
      "permission_mode": stringSchema,
      "network_access": boolSchema,
      "thread_id": stringSchema,
      "turn_id": stringSchema,
      "provider_session_id": stringSchema,
      "provider_run_id": stringSchema,
      "current_step": stringSchema,
      "changed_files": arraySchema(stringSchema),
      "recent_events": arraySchema(taskEventSchema),
      "recent_activity": arraySchema(taskActivitySchema),
      "recent_activity_available": boolSchema,
      "supervisor_status": stringSchema,
      "supervisor_summary": stringSchema,
      "local_approval_required": boolSchema,
      "result_summary": stringSchema,
      "failure_code": stringSchema,
      "updated_at": stringSchema,
      "wait_policy": taskWaitPolicySchema,
    ],
    required: [
      "task_id", "project_id", "status", "changed_files", "recent_events",
      "recent_activity_available",
      "execution_model", "execution_effort", "permission_mode", "network_access",
      "supervisor_status",
      "local_approval_required", "updated_at", "wait_policy",
    ]
  )

  static let errorSchema = objectSchema(
    properties: [
      "code": stringSchema,
      "category": errorCategorySchema,
      "message": stringSchema,
      "retryable": boolSchema,
      "next_action": stringSchema,
      "owner": stringSchema,
      "task_id": stringSchema,
      "operation_id": stringSchema,
      "session_id": stringSchema,
      "data": MCPSharedToolSchemas.errorData,
    ],
    required: ["code", "category", "message", "retryable", "next_action"]
  )

  static let errorCategorySchema: Value = [
    "type": "string",
    "enum": [
      "caller_error", "state_conflict", "policy_denied", "approval_required",
      "capability_unavailable", "infrastructure_failure",
    ],
  ]

  static let stringSchema: Value = ["type": "string"]
  static let boolSchema: Value = ["type": "boolean"]

  static func receiptTypeSchema(_ values: [String]) -> Value {
    if values.count == 1, let value = values.first {
      return ["type": "string", "const": .string(value)]
    }
    return ["type": "string", "enum": .array(values.map(Value.string))]
  }

  static func boundedStringSchema(maximum: Int) -> Value {
    ["type": "string", "maxLength": .int(maximum)]
  }

  static func nullableStringSchema(maximum: Int) -> Value {
    ["type": ["string", "null"], "maxLength": .int(maximum)]
  }

  static func nullableStringSchema(maximum: Int, description: String) -> Value {
    [
      "type": ["string", "null"],
      "maxLength": .int(maximum),
      "description": .string(description),
    ]
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
    required: [String],
    successSchemaVersion: Int = 1
  ) -> Value {
    var fields = properties
    fields["schema_version"] = integerSchema(minimum: 1)
    fields["error"] = errorSchema
    guard case .object(var result) = objectSchema(properties: fields, required: ["schema_version"])
    else {
      preconditionFailure("Output schema must be an object.")
    }
    var success: [String: Value] = [
      "properties": ["schema_version": ["const": .int(successSchemaVersion)]],
      "not": ["required": ["error"]],
    ]
    if !required.isEmpty {
      success["required"] = .array(required.map(Value.string))
    }
    result["oneOf"] = [
      .object(success),
      [
        "properties": ["schema_version": ["const": 1]],
        "required": ["error"],
      ],
    ]
    return .object(result)
  }
}
