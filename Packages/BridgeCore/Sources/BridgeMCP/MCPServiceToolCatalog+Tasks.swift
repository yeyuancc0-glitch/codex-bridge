import MCP

extension MCPServiceToolCatalog {
  static let runSkillAction = Tool(
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
    outputSchema: directExecOutputSchema
  )

  static let getTask = Tool(
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

  static let submitTask = Tool(
    name: MCPServiceToolName.submitTask.rawValue,
    title: "Submit task",
    description:
      "Create and start a Codex task. Risky Codex operations still require local approval. "
      + "Codex is the default execution path. Prefer this tool unless the user explicitly asked "
      + "the MCP client to modify files or run commands directly.",
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

  static let steerTask = Tool(
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

  static let interruptTask = Tool(
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

  static let mutationOutputSchema = outputSchema(
    properties: [
      "task_id": stringSchema,
      "status": stringSchema,
      "accepted": boolSchema,
    ],
    required: ["task_id", "status", "accepted"]
  )
}
