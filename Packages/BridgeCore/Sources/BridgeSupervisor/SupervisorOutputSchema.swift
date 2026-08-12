import Foundation

public enum SupervisorJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([SupervisorJSONValue])
  case object([String: SupervisorJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([SupervisorJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: SupervisorJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

public enum SupervisorOutputSchema {
  public static let decision: SupervisorJSONValue = .object([
    "type": .string("object"),
    "additionalProperties": .bool(false),
    "required": .array([
      .string("decision"),
      .string("risk"),
      .string("summary"),
      .string("evidence"),
      .string("instruction"),
      .string("required_checks"),
      .string("scope_violation"),
      .string("confidence"),
    ]),
    "properties": .object([
      "decision": enumString(SupervisorDecisionKind.allCases.map(\.rawValue)),
      "risk": enumString(SupervisorRisk.allCases.map(\.rawValue)),
      "summary": boundedString(maximumLength: SupervisorDecisionLimits.maximumSummaryBytes),
      "evidence": boundedStringArray(
        maximumItems: SupervisorDecisionLimits.maximumEvidenceItems,
        maximumItemLength: SupervisorDecisionLimits.maximumEvidenceItemBytes
      ),
      "instruction": nullableString(
        maximumLength: SupervisorDecisionLimits.maximumInstructionBytes
      ),
      "required_checks": boundedStringArray(
        maximumItems: SupervisorDecisionLimits.maximumRequiredChecks,
        maximumItemLength: SupervisorDecisionLimits.maximumRequiredCheckBytes
      ),
      "scope_violation": .object(["type": .string("boolean")]),
      "confidence": .object([
        "type": .string("number"),
        "minimum": .number(0),
        "maximum": .number(1),
      ]),
      "issue_id": nullableString(maximumLength: SupervisorDecisionLimits.maximumIssueIDBytes),
    ]),
    "allOf": .array([
      .object([
        "if": decisionCondition([SupervisorDecisionKind.steer.rawValue]),
        "then": .object([
          "required": .array([.string("instruction"), .string("issue_id")]),
          "properties": .object([
            "instruction": boundedString(
              maximumLength: SupervisorDecisionLimits.maximumInstructionBytes
            ),
            "issue_id": boundedString(
              maximumLength: SupervisorDecisionLimits.maximumIssueIDBytes
            ),
          ]),
        ]),
        "else": .object([
          "properties": .object([
            "instruction": .object(["type": .string("null")])
          ])
        ]),
      ]),
      .object([
        "if": decisionCondition([
          SupervisorDecisionKind.steer.rawValue,
          SupervisorDecisionKind.suspend.rawValue,
          SupervisorDecisionKind.interrupt.rawValue,
          SupervisorDecisionKind.finalReject.rawValue,
        ]),
        "then": .object([
          "required": .array([.string("issue_id")]),
          "properties": .object([
            "issue_id": boundedString(
              maximumLength: SupervisorDecisionLimits.maximumIssueIDBytes
            )
          ]),
        ]),
        "else": .object([
          "properties": .object([
            "issue_id": .object(["type": .string("null")])
          ])
        ]),
      ]),
    ]),
  ])

  public static func encodedDecisionSchema(using encoder: JSONEncoder = JSONEncoder()) throws
    -> Data
  {
    try encoder.encode(decision)
  }

  private static func enumString(_ values: [String]) -> SupervisorJSONValue {
    .object([
      "type": .string("string"),
      "enum": .array(values.map(SupervisorJSONValue.string)),
    ])
  }

  private static func boundedString(maximumLength: Int) -> SupervisorJSONValue {
    .object([
      "type": .string("string"),
      "minLength": .number(1),
      "maxLength": .number(Double(maximumLength)),
    ])
  }

  private static func nullableString(maximumLength: Int) -> SupervisorJSONValue {
    .object([
      "anyOf": .array([
        boundedString(maximumLength: maximumLength),
        .object(["type": .string("null")]),
      ])
    ])
  }

  private static func boundedStringArray(
    maximumItems: Int,
    maximumItemLength: Int
  ) -> SupervisorJSONValue {
    .object([
      "type": .string("array"),
      "maxItems": .number(Double(maximumItems)),
      "items": boundedString(maximumLength: maximumItemLength),
    ])
  }

  private static func decisionCondition(_ decisions: [String]) -> SupervisorJSONValue {
    .object([
      "properties": .object([
        "decision": .object([
          "enum": .array(decisions.map(SupervisorJSONValue.string))
        ])
      ]),
      "required": .array([.string("decision")]),
    ])
  }
}
