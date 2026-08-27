import MCP

enum MCPSharedToolSchemas {
  static let opaqueProjectID: Value = [
    "type": "string",
    "maxLength": 128,
    "description":
      "Opaque project ID returned by list_projects, for example prj-.... Never pass the display name.",
  ]

  static let optionalOpaqueProjectID: Value = [
    "type": ["string", "null"],
    "maxLength": 128,
    "description":
      "Opaque project ID returned by list_projects, for example prj-.... This field is optional. Never pass the display name.",
  ]

  static let errorData: Value = [
    "type": "object",
    "properties": [
      "relative_path": ["type": "string"],
      "current_sha256": ["type": "string"],
      "changed_since_revision": ["type": "string"],
      "removed_lines": ["type": "string"],
      "added_lines": ["type": "string"],
      "truncated": ["type": "string"],
      "byte_count": ["type": "string"],
      "changed_files": ["type": "string"],
      "rollback_status": ["type": "string"],
    ],
    "additionalProperties": false,
  ]
}
