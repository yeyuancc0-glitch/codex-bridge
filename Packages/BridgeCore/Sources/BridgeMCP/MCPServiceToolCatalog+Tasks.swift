import MCP

extension MCPServiceToolCatalog {
  static let runSkillAction = Tool(
    name: MCPServiceToolName.runSkillAction.rawValue,
    title: "Run skill action",
    description:
      "Run a discovered Skill script through the project's existing Direct command policy. "
      + "Use only when the user explicitly requests local Skill script execution. This is not "
      + "a general command execution tool. Do not use it for pwd, git, swift, xcodebuild, or "
      + "arbitrary scripts; use direct_exec_project_command instead.",
    inputSchema: objectSchema(
      properties: [
        "skill_name": boundedStringSchema(maximum: 128),
        "action_name": boundedStringSchema(maximum: 128),
        "arguments": arraySchema(boundedStringSchema(maximum: 4_096)),
        "project_id": opaqueProjectIDSchema,
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
    outputSchema: skillActionOutputSchema
  )

  static let getTask = Tool(
    name: MCPServiceToolName.getTask.rawValue,
    title: "Get task",
    description:
      "Read task state, lifecycle events, recent provider activity, result and Supervisor state. "
      + "While running, recent_activity exposes bounded reasoning, text and tool lifecycle updates, "
      + "recent_activity_available reports whether that projection could be read, and updated_at "
      + "reflects the latest persisted provider activity. After submit_task returns "
      + "awaiting_local_approval, poll this tool until the local user approves or denies the "
      + "provider invocation. A denial returns failed with failure_code local_approval_denied. "
      + "The response wait_policy is executable polling guidance: fast means wait 120 seconds "
      + "for approval, standard means wait 300 seconds for active work, and deep means wait 600 "
      + "seconds when a long provider run has no recent activity. Do not poll before the returned "
      + "recommended_poll_after_seconds unless the user asks; a non-terminal status, unchanged "
      + "updated_at, or empty recent_activity is not a failure. Only a terminal status is "
      + "authoritative; use diagnostic_after_quiet_seconds for a diagnostic check, not to infer failure.",
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
      + "opencode or deepseek-harness). DeepSeek Harness is experimental and supports fresh "
      + "sessions with provider-native read-only or workspace-write sandbox modes; omit thread_id, "
      + "supervisor_model and supervisor_effort, and use an explicitly requested model, effort, "
      + "permission mode, or Skill only when it is supported by the registered installation. "
      + "Its execution-time permission requests are surfaced for one-shot local approval. For "
      + "OpenCode, omit permission_mode to use the saved Bridge default. Set "
      + "permission_mode_override=true together with permission_mode only when the user explicitly "
      + "asks for native ACP Plan/read-only or native ACP Build/workspace-write; an unmarked client-selected "
      + "mode is ignored. OpenCode network access follows its native permissions; the "
      + "network_access field does not override them. OpenCode supports model override through the same model_override rule as "
      + "Codex. For OpenCode, execution_effort accepts only the selected model's ACP effort values; "
      + "when omitted, Bridge uses the saved OpenCode default when supported and otherwise the Provider default. "
      + "If permission_mode is omitted, Bridge uses the saved OpenCode default mode; supervisor, "
      + "and skill fields must also be omitted. To continue an OpenCode conversation, pass the "
      + "provider_session_id returned by get_task as thread_id; Bridge resumes or loads that exact "
      + "ACP session in the selected project. The response includes wait_policy; follow "
      + "its recommended_poll_after_seconds before checking get_task again. The three profiles are "
      + "fast (120 seconds, approval), standard (300 seconds, default active work), and deep (600 "
      + "seconds, quiet long-running work). A DeepSeek Harness network_enforcement of unavailable "
      + "means network_access=false does not guarantee blocking the Harness model control plane or "
      + "shell-tool network. Never treat a non-terminal status or unchanged "
      + "updated_at as failure.",
    inputSchema: objectSchema(
      properties: [
        "project_id": optionalOpaqueProjectIDSchema,
        "prompt": boundedStringSchema(maximum: 32 * 1_024),
        "skill_name": nullableStringSchema(maximum: 128),
        "thread_id": nullableStringSchema(maximum: 1_024),
        "provider_id": nullableStringSchema(
          maximum: 64,
          description:
            "Omit for Codex. Set to opencode or deepseek-harness only when the user explicitly selected a locally registered installation; list_agents shows availability and enforcement."
        ),
        "installation_id": nullableStringSchema(
          maximum: 256,
          description:
            "Optional exact registered installation for the chosen provider; omit to let Bridge pick its enabled installation."
        ),
        "execution_model": nullableStringSchema(
          maximum: 256,
          description:
            "Omit to use the Codex Bridge default or the selected provider default. For OpenCode or DeepSeek Harness, use only a model advertised by the local Provider catalog."
        ),
        "execution_effort": nullableStringSchema(
          maximum: 64,
          description:
            "Omit to use the selected provider default effort. For OpenCode or DeepSeek Harness, set only a value advertised for the selected model when the user explicitly requests a per-task override."
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
            "For Codex, selects the native sandbox. For OpenCode, this is applied only when permission_mode_override is true; read-only maps to native ACP Plan and workspace-write maps to native ACP Build. DeepSeek Harness applies read-only or workspace-write to a private provider profile and surfaces execution-time permission requests for one-shot local approval.",
        ],
        "permission_mode_override": [
          "type": ["boolean", "null"],
          "description":
            "For OpenCode, set true only when the user's request explicitly asks for Plan/read-only or Build/workspace-write. Otherwise omit so Bridge uses the saved default mode; a supplied unmarked permission_mode is ignored.",
        ],
        "network_access": [
          "type": "boolean",
          "description":
            "Requests network access for Codex. OpenCode follows its native permissions and this field does not override them. For DeepSeek Harness, network enforcement is unavailable: false does not guarantee blocking model control-plane or shell-tool network access.",
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
        "receipt_type": receiptTypeSchema(["provider_task"]),
        "task_id": stringSchema,
        "status": stringSchema,
        "reused_existing_task": boolSchema,
        "local_approval_required": boolSchema,
        "wait_policy": taskWaitPolicySchema,
      ],
      required: [
        "receipt_type", "task_id", "status", "reused_existing_task",
        "local_approval_required", "wait_policy",
      ]
    )
  )

  static let steerTask = Tool(
    name: MCPServiceToolName.steerTask.rawValue,
    title: "Steer task",
    description:
      "Send bounded corrective input to the exact active provider run. For Codex this is sent to the active Turn; for OpenCode and DeepSeek Harness, pass provider_run_id from get_task as expected_turn_id and the input is queued as the next prompt on the same ACP session. This is a queued follow-up for those ACP providers, not real-time insertion into the current prompt.",
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
      "Request interruption of the exact active provider run. For Codex, expected_turn_id is the active Turn ID; for OpenCode and DeepSeek Harness, use provider_run_id from get_task.",
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
      "receipt_type": receiptTypeSchema(["task_mutation"]),
      "task_id": stringSchema,
      "status": stringSchema,
      "accepted": boolSchema,
    ],
    required: ["receipt_type", "task_id", "status", "accepted"]
  )
}
