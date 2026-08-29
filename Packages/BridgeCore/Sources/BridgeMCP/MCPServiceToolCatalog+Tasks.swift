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
      + "DeepSeek Harness uses its verified native tool composition; Web, network, MCP, file, command, "
      + "and subagent work should be routed to it when the registered installation exposes those "
      + "capabilities. Its execution-time permission requests are surfaced for local approval. For "
      + "OpenCode, omit permission_mode to use the saved Bridge default. A read-only value may "
      + "always narrow that default. Set permission_mode_override=true with workspace-write only "
      + "when the user explicitly asks for native ACP Build. OpenCode network access follows its native permissions; the "
      + "network_access field does not override them. OpenCode supports model override through the same model_override rule as "
      + "Codex. For OpenCode, execution_effort accepts only the selected model's ACP effort values; "
      + "when omitted, Bridge uses the saved OpenCode default when supported and otherwise the Provider default. "
      + "If permission_mode is omitted, Bridge uses the saved OpenCode default mode; supervisor, "
      + "and skill fields must also be omitted. To continue an OpenCode conversation, pass the "
      + "provider_session_id returned by get_task as thread_id; Bridge resumes or loads that exact "
      + "ACP session in the selected project. For Antigravity, set provider_id=antigravity; it "
      + "uses the registered official agy stream-json installation and supports native plan/accept-edits "
      + "modes: Plan/read-only "
      + "(agy mode: plan) or Accept Edits/workspace-write (agy mode: accept-edits) in-place modes. "
      + "Model, effort, and session continuation are "
      + "available only when list_agents reports the corresponding effective capability; thread_id "
      + "must be a prior Bridge-bound Antigravity conversation from the same project and installation. "
      + "steer_task queues follow-up input on the same Antigravity session after the current prompt, "
      + "not real-time insertion. Bridge can inject an explicitly requested skill_name. Antigravity "
      + "does not support Supervisor. Network and sandboxed tools follow agy's native policy; Bridge "
      + "must not reject a task solely because it requests network access. A provider permission denial "
      + "is reported as task failure. The response includes wait_policy; follow "
      + "its recommended_poll_after_seconds before checking get_task again. The three profiles are "
      + "fast (120 seconds, approval), standard (300 seconds, default active work), and deep (600 "
      + "seconds, quiet long-running work). External Provider network execution is Provider-native; "
      + "network_access records the user's explicit task request but does not claim Bridge-level packet "
      + "isolation. Set network_access=true whenever the user explicitly requests web search, URL "
      + "fetches, external APIs, or other network use; false or omitted does not grant task-level "
      + "network access. For Antigravity, a locally selected full-access mode plus network_access=true "
      + "uses agy's documented non-interactive approval while retaining agy's native sandbox and the "
      + "requested Plan/Accept Edits mode. Bridge controls task admission, project policy, and local "
      + "start approval without wrapping Agent processes in a filesystem or network sandbox. Never "
      + "treat a non-terminal status or unchanged "
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
            "Omit for Codex. Set to opencode, deepseek-harness, or antigravity only when the user explicitly selected a locally registered installation; list_agents shows availability, effective capabilities, and enforcement."
        ),
        "installation_id": nullableStringSchema(
          maximum: 256,
          description:
            "Optional exact registered installation for the chosen provider; omit to let Bridge pick its enabled installation."
        ),
        "execution_model": nullableStringSchema(
          maximum: 256,
          description:
            "Omit to use the Codex Bridge default or the selected provider default. For OpenCode, DeepSeek Harness, or Antigravity, use only a model advertised by the local Provider catalog when selection.model is effective."
        ),
        "execution_effort": nullableStringSchema(
          maximum: 64,
          description:
            "Omit to use the selected provider default effort. For OpenCode, DeepSeek Harness, or Antigravity, set only a value advertised for the selected model when the user explicitly requests a per-task override and selection.effort is effective; external providers require model_override=true."
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
            "For Codex, selects the native sandbox. For external agents, read-only may always narrow the saved mode; workspace-write requires permission_mode_override=true. OpenCode maps these modes to native ACP Plan/Build. DeepSeek Harness applies them to a private provider profile and surfaces execution-time permission requests for local approval. Antigravity selects agy Plan or Accept Edits and uses its native sandbox permission policy for headless tools.",
        ],
        "permission_mode_override": [
          "type": ["boolean", "null"],
          "description":
            "Set true only when the user explicitly requests workspace-write or another per-task permission override. Read-only may be supplied without this marker to narrow an external agent's saved mode.",
        ],
        "network_access": [
          "type": "boolean",
          "description":
            "Set true whenever the user's task explicitly requires web search, URL fetches, external APIs, or other network use. False or omitted does not grant task-level network access. Codex applies its native sandbox policy. OpenCode, DeepSeek Harness, and Antigravity execute network-capable tools under their Provider-native policies; this field records the explicit request and project admission but does not claim Bridge-level packet isolation.",
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
      "Send bounded corrective input to the exact active provider run. The default queued mode preserves existing behavior. For DeepSeek Harness, mode=interrupt-current-then-continue cancels only the current prompt and sends the correction on the same session without terminating the task. Other external providers currently accept queued mode only.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "expected_turn_id": boundedStringSchema(maximum: 1_024),
        "input": boundedStringSchema(maximum: 32 * 1_024),
        "mode": [
          "type": "string",
          "enum": ["queued", "interrupt-current-then-continue"],
          "description":
            "Delivery mode. Omit or use queued for compatibility. interrupt-current-then-continue is available only when list_agents reports lifecycle.steer_interrupt_and_continue.",
        ],
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
      "Request interruption of the exact active provider run. For Codex, expected_turn_id is the active Turn ID; for OpenCode, DeepSeek Harness, and Antigravity, use provider_run_id from get_task.",
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
