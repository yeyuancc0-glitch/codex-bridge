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
    description:
      "Read task state, recent events, result and Supervisor state. After submit_task returns "
      + "awaiting_local_approval, poll this tool until the local user approves or denies the "
      + "provider invocation. A denial returns failed with failure_code local_approval_denied.",
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
      "Create a provider task; Codex remains the default provider. ChatGPT and Qwen submissions "
      + "wait for the local user to approve the provider invocation in Codex Bridge before "
      + "execution starts. Return immediately with "
      + "awaiting_local_approval and local_approval_required=true, then use get_task to observe "
      + "approval, execution, or an explicit local_approval_denied result. Risky Codex operations "
      + "can still require additional local approval after execution starts. "
      + "Codex is the default execution path. Prefer this tool unless the user explicitly asked "
      + "the MCP client to modify files or run commands directly. Omit project_id to use the "
      + "project currently selected in the Codex Bridge workbench; an explicit project_id overrides "
      + "that default. Omit all model and effort fields unless the user explicitly requests a "
      + "different model for this task; omitted values use the defaults configured in Codex Bridge. "
      + "Model and effort fields are applied only when model_override is true. "
      + "Set provider_id to route the task to another registered agent provider (for example "
      + "opencode). For OpenCode, permission_mode selects its native ACP Plan (read-only) or "
      + "native ACP Build (workspace-write). OpenCode network access follows its native permissions; the "
      + "network_access field does not override them. OpenCode supports model override through the same model_override rule as "
      + "Codex, but execution_effort is not an OpenCode ACP option and must be omitted; supervisor, "
      + "skill and thread fields must also be omitted.",
    inputSchema: objectSchema(
      properties: [
        "project_id": boundedStringSchema(maximum: 128),
        "prompt": boundedStringSchema(maximum: 32 * 1_024),
        "skill_name": nullableStringSchema(maximum: 128),
        "thread_id": nullableStringSchema(maximum: 1_024),
        "provider_id": nullableStringSchema(
          maximum: 64,
          description:
            "Omit for Codex. Set to opencode to run the task with a locally registered OpenCode installation; list_agents shows availability."
        ),
        "installation_id": nullableStringSchema(
          maximum: 256,
          description:
            "Optional exact registered installation for the chosen provider; omit to let Bridge pick its enabled installation."
        ),
        "execution_model": nullableStringSchema(
          maximum: 256,
          description:
            "Omit to use the Codex Bridge default. Set only when the user explicitly requests a per-task model override."
        ),
        "execution_effort": nullableStringSchema(
          maximum: 64,
          description:
            "Omit to use the Codex Bridge default effort. Set only with an explicit user-requested Codex override; OpenCode does not accept this field."
        ),
        "model_override": [
          "type": ["boolean", "null"],
          "description":
            "Set true only when the user explicitly requests a per-task model or effort override. Otherwise omit; supplied model fields are ignored for compatibility.",
        ],
        "supervisor_model": nullableStringSchema(
          maximum: 256,
          description:
            "Omit to use the Codex Bridge Supervisor default. Set only when the user explicitly requests an override."
        ),
        "supervisor_effort": nullableStringSchema(
          maximum: 64,
          description:
            "Omit to use the Codex Bridge Supervisor default effort. Set only with an explicit user-requested override."
        ),
        "permission_mode": [
          "type": ["string", "null"],
          "enum": ["read-only", "workspace-write", .null],
          "description":
            "For Codex, selects the native sandbox. For OpenCode, read-only maps to native ACP Plan and workspace-write maps to native ACP Build.",
        ],
        "network_access": [
          "type": "boolean",
          "description":
            "Requests network access for Codex. OpenCode follows its native permissions and this field does not override them.",
        ],
        "acceptance_criteria": [
          "type": "array",
          "maxItems": 32,
          "items": boundedStringSchema(maximum: 4_096),
        ],
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["prompt"]
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
    description:
      "Request interruption of the exact active provider run. For Codex, expected_turn_id is the active Turn ID; for OpenCode, use provider_run_id from get_task.",
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
