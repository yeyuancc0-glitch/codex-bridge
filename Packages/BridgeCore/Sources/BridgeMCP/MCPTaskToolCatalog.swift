import MCP

extension MCPToolCatalog {
  static let getTask = Tool(
    name: MCPTaskToolName.getTask.rawValue,
    title: "Get task",
    description: "Read the latest event-sourced state and bounded progress summary for one task.",
    inputSchema: taskIDInputSchema,
    annotations: readOnlyTaskAnnotations,
    outputSchema: taskOutputSchema(
      properties: ["task": taskSnapshotSchema],
      required: ["task"]
    )
  )

  static let getTaskEvents = Tool(
    name: MCPTaskToolName.getTaskEvents.rawValue,
    title: "Get task events",
    description: "Read a monotonic, cursor-paginated page of sanitized task events.",
    inputSchema: taskObjectSchema(
      properties: [
        "task_id": taskBoundedString(128),
        "after_seq": taskNullableInteger(minimum: 0),
        "limit": taskInteger(minimum: 1, maximum: 100),
      ],
      required: ["task_id"]
    ),
    annotations: readOnlyTaskAnnotations,
    outputSchema: taskOutputSchema(
      properties: [
        "task_id": taskString,
        "events": taskArray(taskEventSchema),
        "next_after_seq": taskInteger(minimum: 0),
      ],
      required: ["task_id", "events"]
    )
  )

  static let getTaskDiff = Tool(
    name: MCPTaskToolName.getTaskDiff.rawValue,
    title: "Get task diff",
    description: "Read Git file statistics or one bounded patch page for a task.",
    inputSchema: taskObjectSchema(
      properties: [
        "task_id": taskBoundedString(128),
        "cursor": taskNullableString(2_048),
        "limit": taskInteger(minimum: 1, maximum: 100),
        "include_patch": ["type": "boolean"],
      ],
      required: ["task_id"]
    ),
    annotations: readOnlyTaskAnnotations,
    outputSchema: taskOutputSchema(
      properties: [
        "task_id": taskString,
        "files": taskArray(taskDiffFileSchema),
        "diff_stat": taskString,
        "patch": taskString,
        "next_cursor": taskString,
        "baseline_was_dirty": ["type": "boolean"],
      ],
      required: ["task_id", "files", "diff_stat", "baseline_was_dirty"]
    )
  )

  static let getFinalReport = Tool(
    name: MCPTaskToolName.getFinalReport.rawValue,
    title: "Get final report",
    description: "Read the structured, evidence-backed final report for a terminal task.",
    inputSchema: taskIDInputSchema,
    annotations: readOnlyTaskAnnotations,
    outputSchema: taskOutputSchema(
      properties: ["report": finalReportSchema],
      required: ["report"]
    )
  )

  static let submitTask = Tool(
    name: MCPTaskToolName.submitTask.rawValue,
    title: "Submit task",
    description: "Idempotently create a task contract and return immediately with its local state.",
    inputSchema: taskSubmissionSchema,
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    ),
    outputSchema: taskOutputSchema(
      properties: [
        "task_id": taskString,
        "phase": taskString,
        "reused_existing_task": ["type": "boolean"],
        "local_approval_required": ["type": "boolean"],
      ],
      required: [
        "task_id", "phase", "reused_existing_task", "local_approval_required",
      ]
    )
  )

  static let steerTask = Tool(
    name: MCPTaskToolName.steerTask.rawValue,
    title: "Steer task",
    description: "Append bounded corrective input only to the explicitly expected active turn.",
    inputSchema: taskObjectSchema(
      properties: [
        "task_id": taskBoundedString(128),
        "expected_turn_id": taskBoundedString(256),
        "input": taskBoundedString(32 * 1_024),
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
    name: MCPTaskToolName.interruptTask.rawValue,
    title: "Interrupt task",
    description: "Persist an interrupt intent and request that the task's active turn stop.",
    inputSchema: taskIDInputSchema,
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  private static let readOnlyTaskAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let taskIDInputSchema = taskObjectSchema(
    properties: ["task_id": taskBoundedString(128)],
    required: ["task_id"]
  )

  private static let taskSubmissionSchema = taskObjectSchema(
    properties: [
      "idempotency_key": taskBoundedString(512),
      "project_id": taskBoundedString(128),
      "thread": threadTargetSchema,
      "execution": taskObjectSchema(
        properties: [
          "model": taskBoundedString(128),
          "effort": taskBoundedString(64),
          "permission_mode": [
            "type": "string",
            "enum": ["read-only", "workspace-write", "readOnly", "workspaceWrite"],
          ],
          "network_access": ["type": "boolean"],
        ],
        required: ["model", "effort", "permission_mode", "network_access"]
      ),
      "supervisor": taskObjectSchema(
        properties: [
          "enabled": ["type": "boolean"],
          "model": taskBoundedString(128),
          "effort": taskBoundedString(64),
        ],
        required: ["enabled", "model", "effort"]
      ),
      "contract": taskObjectSchema(
        properties: [
          "goal": taskBoundedString(32 * 1_024),
          "background": taskBoundedString(64 * 1_024),
          "requirements": boundedTaskTextArray,
          "acceptance_criteria": boundedTaskTextArray,
          "non_goals": boundedTaskTextArray,
          "constraints": boundedTaskTextArray,
          "allowed_paths": boundedTaskPathArray,
          "forbidden_paths": boundedTaskPathArray,
          "verification": boundedTaskTextArray,
        ],
        required: [
          "goal", "background", "requirements", "acceptance_criteria", "non_goals",
          "constraints", "allowed_paths", "forbidden_paths", "verification",
        ]
      ),
    ],
    required: [
      "idempotency_key", "project_id", "thread", "execution", "supervisor", "contract",
    ]
  )

  private static let boundedTaskTextArray: Value = [
    "type": "array",
    "maxItems": 100,
    "items": taskBoundedString(4_096),
  ]

  private static let threadTargetSchema: Value = {
    guard
      case .object(var schema) = taskObjectSchema(
        properties: [
          "mode": ["type": "string", "enum": ["new", "existing"]],
          "thread_id": taskNullableString(256),
        ],
        required: ["mode"]
      )
    else {
      preconditionFailure("Thread target schema must be an object.")
    }
    schema["oneOf"] = [
      [
        "properties": [
          "mode": ["const": "new"],
          "thread_id": ["type": "null"],
        ]
      ],
      [
        "properties": [
          "mode": ["const": "existing"],
          "thread_id": taskBoundedString(256),
        ],
        "required": ["thread_id"],
      ],
    ]
    return .object(schema)
  }()

  private static let boundedTaskPathArray: Value = [
    "type": "array",
    "maxItems": 200,
    "items": taskBoundedString(1_024),
  ]

  private static let taskSnapshotSchema = taskObjectSchema(
    properties: [
      "task_id": taskString,
      "phase": taskString,
      "activity": taskString,
      "thread_id": taskString,
      "turn_id": taskString,
      "current_plan": taskArray(taskString),
      "current_step": taskString,
      "supervisor_state": taskString,
      "changed_file_count": taskInteger(minimum: 0),
      "verification_summary": taskString,
      "final_report_available": ["type": "boolean"],
      "updated_at": taskString,
    ],
    required: [
      "task_id", "phase", "activity", "current_plan", "supervisor_state",
      "changed_file_count", "final_report_available",
    ]
  )

  private static let taskEventSchema = taskObjectSchema(
    properties: [
      "seq": taskInteger(minimum: 0),
      "kind": taskString,
      "occurred_at": taskString,
      "summary": taskString,
    ],
    required: ["seq", "kind"]
  )

  private static let taskDiffFileSchema = taskObjectSchema(
    properties: [
      "relative_path": taskString,
      "status": taskString,
      "additions": taskInteger(minimum: 0),
      "deletions": taskInteger(minimum: 0),
    ],
    required: ["relative_path", "status"]
  )

  private static let finalReportSchema = taskObjectSchema(
    properties: [
      "task_id": taskString,
      "status": taskString,
      "project": taskString,
      "thread_id": taskString,
      "execution_model": taskString,
      "execution_effort": taskString,
      "summary": taskString,
      "changed_files": taskArray(taskString),
      "diff_stat": taskString,
      "commands": taskArray(taskString),
      "verification": taskArray(taskString),
      "warnings": taskArray(taskString),
      "unresolved_items": taskArray(taskString),
      "commit": taskString,
      "started_at": taskString,
      "completed_at": taskString,
    ],
    required: [
      "task_id", "status", "project", "execution_model", "execution_effort", "summary",
      "changed_files", "diff_stat", "commands", "verification", "warnings",
      "unresolved_items", "started_at", "completed_at",
    ]
  )

  private static let mutationOutputSchema = taskOutputSchema(
    properties: [
      "task_id": taskString,
      "phase": taskString,
      "accepted": ["type": "boolean"],
      "operation_id": taskString,
    ],
    required: ["task_id", "phase", "accepted", "operation_id"]
  )

  private static let taskErrorSchema = taskObjectSchema(
    properties: [
      "code": taskString,
      "message": taskString,
      "retryable": ["type": "boolean"],
    ],
    required: ["code", "message", "retryable"]
  )

  private static let taskString: Value = ["type": "string"]

  private static func taskBoundedString(_ maximumLength: Int) -> Value {
    ["type": "string", "maxLength": .int(maximumLength)]
  }

  private static func taskNullableString(_ maximumLength: Int) -> Value {
    ["type": ["string", "null"], "maxLength": .int(maximumLength)]
  }

  private static func taskInteger(minimum: Int, maximum: Int? = nil) -> Value {
    var value: [String: Value] = ["type": "integer", "minimum": .int(minimum)]
    if let maximum { value["maximum"] = .int(maximum) }
    return .object(value)
  }

  private static func taskNullableInteger(minimum: Int) -> Value {
    ["type": ["integer", "null"], "minimum": .int(minimum)]
  }

  private static func taskArray(_ items: Value) -> Value {
    ["type": "array", "items": items]
  }

  private static func taskObjectSchema(
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

  private static func taskOutputSchema(
    properties: [String: Value],
    required: [String]
  ) -> Value {
    var allProperties = properties
    allProperties["schema_version"] = ["type": "integer", "const": 1]
    allProperties["error"] = taskErrorSchema
    guard
      case .object(var schema) = taskObjectSchema(
        properties: allProperties,
        required: ["schema_version"]
      )
    else {
      preconditionFailure("Task output schema must be an object.")
    }
    schema["oneOf"] = [
      ["required": .array(required.map(Value.string))],
      ["required": ["error"]],
    ]
    return .object(schema)
  }
}
